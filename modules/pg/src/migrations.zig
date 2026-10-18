//! Internal: the migrations of modules, on PostgreSQL. Apps call them
//! through `server.migrateModules` (what `spider migrate` runs) and
//! `server.checkModules` (what listen() runs before it starts); this file
//! only knows steps (`module/name` + SQL) and `schema_migrations`.
//!
//! `schema_migrations` is the table `spider migrate` already keeps for the
//! app's own files (`version` primary key, `ran_at`). Modules add a
//! `checksum` column (added here when missing, NULL for the app's rows) and
//! record their migrations as `module/name`, which no file name can be.
//!
//! Each step runs in its own transaction, together with its row, under an
//! advisory lock: two processes migrating at the same time (a deploy) never
//! run the same step twice, and a step that fails leaves nothing behind.

const std = @import("std");
const pg = @import("pg.zig");
const spider = @import("spider");

const Step = spider.migration.Step;
const State = spider.migration.State;

const table_ddl =
    "CREATE TABLE IF NOT EXISTS schema_migrations (" ++
    "version VARCHAR(255) NOT NULL PRIMARY KEY, " ++
    "ran_at TIMESTAMPTZ NOT NULL DEFAULT NOW())";
const checksum_ddl = "ALTER TABLE schema_migrations ADD COLUMN IF NOT EXISTS checksum TEXT";
// One lock for every migrating process: hashtext('spider_migrations').
const lock_sql = "SELECT pg_advisory_xact_lock(hashtext('spider_migrations'))";

const Recorded = struct { version: []const u8, checksum: ?[]const u8 };

// internal: where each step stands, in the order given. Read-only: without
// the table every step is pending. error.DatabaseNotInitialized before
// spider.pg.init.
pub fn status(arena: std.mem.Allocator, steps: []const Step) anyerror![]const State {
    if (!pg.isInitialized()) return error.DatabaseNotInitialized;
    const out = try arena.alloc(State, steps.len);
    @memset(out, .pending);
    if (steps.len == 0) return out;

    const Flags = struct { table: bool, has_checksum: bool };
    const flags = (try pg.queryOne(Flags, arena,
        \\SELECT to_regclass('schema_migrations') IS NOT NULL AS table,
        \\  EXISTS (SELECT 1 FROM information_schema.columns
        \\          WHERE table_schema = current_schema() AND table_name = 'schema_migrations'
        \\            AND column_name = 'checksum') AS has_checksum
    , .{})).?;
    if (!flags.table) return out;

    const keys = try arena.alloc([]const u8, steps.len);
    for (steps, keys) |s, *k| k.* = try spider.migration.key(arena, s.module, s.name);
    const sql = if (flags.has_checksum)
        "SELECT version, checksum FROM schema_migrations WHERE version = ANY($1)"
    else
        "SELECT version, NULL::text AS checksum FROM schema_migrations WHERE version = ANY($1)";
    const rows = try pg.query(Recorded, arena, sql, .{keys});

    for (steps, keys, out) |s, k, *st| {
        for (rows) |r| {
            if (!std.mem.eql(u8, r.version, k)) continue;
            const recorded = r.checksum orelse {
                st.* = .applied;
                break;
            };
            const now = spider.migration.checksum(s.sql);
            st.* = if (std.mem.eql(u8, recorded, &now)) .applied else .changed;
            break;
        }
    }
    return out;
}

// internal: runs every pending step, in order, each in its own transaction
// with its row. Returns how many ran. error.DatabaseNotInitialized before
// spider.pg.init. error.MigrationChanged (nothing more
// runs) when an applied step's SQL differs from what ran;
// error.MigrationHasTransactionControl when a step's SQL holds BEGIN,
// COMMIT or ROLLBACK (the transaction is Spider's); or the database's
// error for a failed step, which is rolled back.
pub fn apply(arena: std.mem.Allocator, steps: []const Step) anyerror!usize {
    if (!pg.isInitialized()) return error.DatabaseNotInitialized;
    try pg.query(void, arena, table_ddl, .{});
    try pg.query(void, arena, checksum_ddl, .{});

    // Refuse before running anything: a step with transaction control would
    // commit Spider's transaction halfway.
    for (steps) |s| {
        var it: pg.Statements = .{ .sql = s.sql };
        while (it.next()) |stmt| {
            if (pg.txControl(stmt) != .none) {
                std.log.err("migration {s}/{s}: remove `{s}`: Spider runs each migration in a transaction of its own", .{ s.module, s.name, firstLine(stmt) });
                return error.MigrationHasTransactionControl;
            }
        }
    }

    var applied: usize = 0;
    for (steps) |s| {
        const k = try spider.migration.key(arena, s.module, s.name);
        const sum = spider.migration.checksum(s.sql);

        var tx = try pg.begin();
        defer tx.rollback();
        try tx.query(void, arena, lock_sql, .{});
        if (try tx.queryOne(struct { checksum: ?[]const u8 }, arena, "SELECT checksum FROM schema_migrations WHERE version = $1", .{k})) |row| {
            if (row.checksum) |recorded| if (!std.mem.eql(u8, recorded, &sum)) {
                std.log.err("migration {s} changed after it was applied (checksum {s}, now {s}): add a new migration instead of editing an applied one", .{ k, recorded, &sum });
                return error.MigrationChanged;
            };
            continue;
        }

        var it: pg.Statements = .{ .sql = s.sql };
        while (it.next()) |stmt| {
            _ = tx.conn.exec(stmt, .{}) catch |err| {
                const typed = pg.fail(tx.conn, err);
                std.log.err("migration {s} failed: {s}", .{ k, @errorName(typed) });
                return typed;
            };
        }
        try tx.query(void, arena, "INSERT INTO schema_migrations (version, checksum) VALUES ($1, $2)", .{ k, @as([]const u8, &sum) });
        try tx.commit();
        applied += 1;
        std.log.info("migration {s} applied", .{k});
    }
    return applied;
}

fn firstLine(stmt: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, stmt, '\n') orelse stmt.len;
    return stmt[0..@min(end, 60)];
}

// ── Tests (need the disposable Postgres of `zig build test-pg`) ──────────

var test_threaded: ?std.Io.Threaded = null;

fn initTestDb(allocator: std.mem.Allocator) !void {
    if (test_threaded == null) test_threaded = std.Io.Threaded.init(allocator, .{});
    try pg.init(allocator, test_threaded.?.io(), .{});
}

fn cleanUp(arena: std.mem.Allocator, module: []const u8, tables: []const []const u8) void {
    for (tables) |t| {
        const sql = std.fmt.allocPrint(arena, "DROP TABLE IF EXISTS {s}", .{t}) catch continue;
        pg.query(void, arena, sql, .{}) catch {};
    }
    const like = std.fmt.allocPrint(arena, "{s}/%", .{module}) catch return;
    pg.query(void, arena, "DELETE FROM schema_migrations WHERE version LIKE $1", .{like}) catch {};
}

test "migrations: pending, applied once, in order, with checksums" {
    try initTestDb(std.testing.allocator);
    defer pg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    defer cleanUp(a, "spidertest_a", &.{ "spidertest_a_items", "spidertest_a_log" });
    cleanUp(a, "spidertest_a", &.{ "spidertest_a_items", "spidertest_a_log" });

    const steps = [_]Step{
        .{ .module = "spidertest_a", .name = "0001_init", .sql = "CREATE TABLE spidertest_a_items (id int PRIMARY KEY); CREATE TABLE spidertest_a_log (msg text)" },
        .{ .module = "spidertest_a", .name = "0002_fn", .sql =
        \\CREATE OR REPLACE FUNCTION spidertest_a_one() RETURNS int LANGUAGE plpgsql AS $$
        \\BEGIN
        \\  RETURN 1;
        \\END $$;
        \\INSERT INTO spidertest_a_items VALUES (spidertest_a_one())
        },
    };
    try std.testing.expectEqualSlices(State, &.{ .pending, .pending }, try status(a, &steps));
    try std.testing.expectEqual(@as(usize, 2), try apply(a, &steps));
    try std.testing.expectEqualSlices(State, &.{ .applied, .applied }, try status(a, &steps));
    try std.testing.expectEqual(@as(usize, 0), try apply(a, &steps)); // again: nothing
    try std.testing.expectEqual(@as(i64, 1), try pg.query(i64, a, "SELECT count(*) FROM spidertest_a_items", .{}));
    const sum = spider.migration.checksum(steps[0].sql);
    try std.testing.expectEqualStrings(&sum, (try pg.queryOne(struct { checksum: []const u8 }, a, "SELECT checksum FROM schema_migrations WHERE version = 'spidertest_a/0001_init'", .{})).?.checksum);
    pg.query(void, a, "DROP FUNCTION IF EXISTS spidertest_a_one()", .{}) catch {};
}

test "migrations: an edited applied migration is reported and refused" {
    try initTestDb(std.testing.allocator);
    defer pg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    defer cleanUp(a, "spidertest_b", &.{"spidertest_b_t"});
    cleanUp(a, "spidertest_b", &.{"spidertest_b_t"});

    const v1 = [_]Step{.{ .module = "spidertest_b", .name = "0001_init", .sql = "CREATE TABLE spidertest_b_t (id int)" }};
    _ = try apply(a, &v1);
    const v2 = [_]Step{.{ .module = "spidertest_b", .name = "0001_init", .sql = "CREATE TABLE spidertest_b_t (id bigint)" }};
    try std.testing.expectEqualSlices(State, &.{.changed}, try status(a, &v2));
    try std.testing.expectError(error.MigrationChanged, apply(a, &v2));
}

test "migrations: a failing step is rolled back whole, and the ones before stay" {
    try initTestDb(std.testing.allocator);
    defer pg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    defer cleanUp(a, "spidertest_c", &.{ "spidertest_c_ok", "spidertest_c_half" });
    cleanUp(a, "spidertest_c", &.{ "spidertest_c_ok", "spidertest_c_half" });

    const steps = [_]Step{
        .{ .module = "spidertest_c", .name = "0001_ok", .sql = "CREATE TABLE spidertest_c_ok (id int)" },
        .{ .module = "spidertest_c", .name = "0002_bad", .sql = "CREATE TABLE spidertest_c_half (id int); SELECT * FROM spidertest_c_missing" },
    };
    try std.testing.expect(std.meta.isError(apply(a, &steps)));
    try std.testing.expectEqualSlices(State, &.{ .applied, .pending }, try status(a, &steps));
    // the half of the failed step is not there
    try std.testing.expect((try pg.queryOne(struct { t: bool }, a, "SELECT to_regclass('spidertest_c_half') IS NULL AS t", .{})).?.t);
}

test "migrations: transaction control in a step is refused before anything runs" {
    try initTestDb(std.testing.allocator);
    defer pg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    defer cleanUp(a, "spidertest_d", &.{"spidertest_d_t"});
    cleanUp(a, "spidertest_d", &.{"spidertest_d_t"});

    const steps = [_]Step{
        .{ .module = "spidertest_d", .name = "0001_ok", .sql = "CREATE TABLE spidertest_d_t (id int)" },
        .{ .module = "spidertest_d", .name = "0002_tx", .sql = "BEGIN; INSERT INTO spidertest_d_t VALUES (1); COMMIT" },
    };
    try std.testing.expectError(error.MigrationHasTransactionControl, apply(a, &steps));
    try std.testing.expectEqualSlices(State, &.{ .pending, .pending }, try status(a, &steps));
}

test "migrations: rows written before checksums count as applied" {
    try initTestDb(std.testing.allocator);
    defer pg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    defer cleanUp(a, "spidertest_e", &.{});
    cleanUp(a, "spidertest_e", &.{});
    try pg.query(void, a, table_ddl, .{});
    try pg.query(void, a, checksum_ddl, .{});
    try pg.query(void, a, "INSERT INTO schema_migrations (version) VALUES ('spidertest_e/0001_x')", .{});
    const steps = [_]Step{.{ .module = "spidertest_e", .name = "0001_x", .sql = "SELECT 1" }};
    try std.testing.expectEqualSlices(State, &.{.applied}, try status(a, &steps));
    try std.testing.expectEqual(@as(usize, 0), try apply(a, &steps));
}
