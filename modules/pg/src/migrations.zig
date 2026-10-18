//! Internal: database migrations on PostgreSQL, a module's and the app's
//! own alike. Apps call them through `server.migrate` (what `spider
//! migrate` runs) and `server.check` (what listen() runs before it starts);
//! this file only knows steps (module, name, SQL) and `schema_migrations`.
//!
//! `schema_migrations` is the table `spider migrate` has always kept for the
//! app's files (`version` primary key, `ran_at`), plus a `checksum` column
//! (added here when missing). A module's migration is recorded as
//! `module/name`, an app's as its bare name, as before, so the rows already
//! there count as applied; the first `apply` records their checksums.
//!
//! Each step runs in its own transaction, together with its row, under an
//! advisory lock: two processes migrating at the same time (a deploy) never
//! run the same step twice, and a step that fails leaves nothing behind. A
//! step that cannot run in a transaction (`CREATE INDEX CONCURRENTLY`) is
//! alone in its migration and runs outside one, under the same lock.

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
const session_lock_sql = "SELECT pg_advisory_lock(hashtext('spider_migrations'))";
const session_unlock_sql = "SELECT pg_advisory_unlock(hashtext('spider_migrations'))";
const recorded_sql = "SELECT checksum FROM schema_migrations WHERE version = $1";
const insert_sql = "INSERT INTO schema_migrations (version, checksum) VALUES ($1, $2)";
const baseline_sql = "UPDATE schema_migrations SET checksum = $2 WHERE version = $1 AND checksum IS NULL";

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

    var recorded: std.StringHashMapUnmanaged(?[]const u8) = .empty;
    try recorded.ensureTotalCapacity(arena, @intCast(rows.len));
    for (rows) |r| recorded.putAssumeCapacity(r.version, r.checksum);
    for (steps, keys, out) |s, k, *st| {
        const entry = recorded.get(k) orelse continue;
        const sum = entry orelse {
            st.* = .applied;
            continue;
        };
        const now = spider.migration.checksum(s.sql);
        st.* = if (std.mem.eql(u8, sum, &now)) .applied else .changed;
    }
    return out;
}

// internal: what runs of a step: its statements, and whether they run in a
// transaction (Spider's) or alone outside one.
const Plan = struct {
    statements: []const []const u8,
    transaction: bool,
};

// internal: the plan of a step, or why it is refused (logged).
// error.MigrationHasTransactionControl for BEGIN, COMMIT, ROLLBACK or a
// savepoint (the transaction is Spider's): an app's migration may still
// wrap all of its SQL in `BEGIN; ... COMMIT;`, as files written for
// `spider migrate` before Spider ran them in a transaction did, and the
// wrapper is left out. error.MigrationNotAlone when a statement that cannot
// run in a transaction shares its migration with others.
fn planOf(arena: std.mem.Allocator, s: Step) !Plan {
    var list: std.ArrayList([]const u8) = .empty;
    var it: pg.Statements = .{ .sql = s.sql };
    while (it.next()) |stmt| {
        // A statement of comments only (a migration whose up part is a
        // note) is nothing to run: PostgreSQL answers it with an empty
        // response.
        if (pg.skipSqlNoise(stmt).len == 0) continue;
        try list.append(arena, stmt);
    }
    var stmts = list.items;
    if (s.ofApp() and stmts.len >= 2 and pg.txControl(stmts[0]) == .open and
        pg.txControl(stmts[stmts.len - 1]) == .close and isCommit(stmts[stmts.len - 1]))
    {
        stmts = stmts[1 .. stmts.len - 1];
    }
    const k = try spider.migration.key(arena, s.module, s.name);
    var alone = false;
    for (stmts) |stmt| {
        if (pg.txControl(stmt) != .none) {
            std.log.err("migration {s}: remove `{s}`: Spider runs each migration in a transaction of its own", .{ k, firstLine(stmt) });
            return error.MigrationHasTransactionControl;
        }
        if (cannotRunInTransaction(stmt)) alone = true;
    }
    if (alone and stmts.len != 1) {
        std.log.err("migration {s}: `{s}` cannot run in a transaction: put it alone in a migration of its own", .{ k, firstLine(firstNonTransactional(stmts)) });
        return error.MigrationNotAlone;
    }
    return .{ .statements = stmts, .transaction = !alone };
}

fn isCommit(stmt: []const u8) bool {
    const w = pg.nextWord(stmt).word;
    return std.ascii.eqlIgnoreCase(w, "COMMIT") or std.ascii.eqlIgnoreCase(w, "END");
}

fn firstNonTransactional(stmts: []const []const u8) []const u8 {
    for (stmts) |stmt| if (cannotRunInTransaction(stmt)) return stmt;
    return stmts[0];
}

// internal: whether PostgreSQL refuses `stmt` inside a transaction block:
// an index built or dropped CONCURRENTLY, VACUUM, a database, a tablespace
// or ALTER SYSTEM.
fn cannotRunInTransaction(stmt: []const u8) bool {
    var words: [4][]const u8 = undefined;
    var rest = stmt;
    for (&words) |*w| {
        const next = pg.nextWord(rest);
        w.* = next.word;
        rest = next.rest;
    }
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(words[0], "VACUUM")) return true;
    if (eq(words[0], "ALTER") and eq(words[1], "SYSTEM")) return true;
    if (eq(words[0], "CREATE") or eq(words[0], "DROP")) {
        if (eq(words[1], "DATABASE") or eq(words[1], "TABLESPACE")) return true;
        const index_at: usize = if (eq(words[1], "UNIQUE")) 2 else 1;
        if (eq(words[index_at], "INDEX") and eq(words[index_at + 1], "CONCURRENTLY")) return true;
    }
    if (eq(words[0], "REINDEX")) return containsWord(stmt, "CONCURRENTLY");
    return false;
}

fn containsWord(stmt: []const u8, word: []const u8) bool {
    var rest = stmt;
    while (true) {
        const next = pg.nextWord(rest);
        if (next.word.len == 0) {
            if (next.rest.len == 0) return false;
            rest = next.rest[1..];
            continue;
        }
        if (std.ascii.eqlIgnoreCase(next.word, word)) return true;
        rest = next.rest;
    }
}

// internal: runs every pending step, in order, each in its own transaction
// with its row; records the checksum of applied steps whose row has none.
// Returns how many ran. error.DatabaseNotInitialized before spider.pg.init.
// Refused before anything runs: error.MigrationHasTransactionControl,
// error.MigrationNotAlone (see planOf). error.MigrationChanged (nothing
// more runs) when an applied step's SQL differs from what ran; or the
// database's error for a failed step, which is rolled back (a step outside
// a transaction is a single statement: it ran or it did not).
pub fn apply(arena: std.mem.Allocator, steps: []const Step) anyerror!usize {
    if (!pg.isInitialized()) return error.DatabaseNotInitialized;

    // Refuse before running anything.
    const plans = try arena.alloc(Plan, steps.len);
    for (steps, plans) |s, *p| p.* = try planOf(arena, s);

    try pg.query(void, arena, table_ddl, .{});
    try pg.query(void, arena, checksum_ddl, .{});

    var applied: usize = 0;
    var baselined: usize = 0;
    for (steps, plans) |s, p| {
        const k = try spider.migration.key(arena, s.module, s.name);
        const sum = spider.migration.checksum(s.sql);
        const outcome = if (p.transaction)
            try applyInTransaction(arena, k, &sum, p.statements)
        else
            try applyAlone(arena, k, &sum, p.statements[0]);
        switch (outcome) {
            .ran => {
                applied += 1;
                std.log.info("migration {s} applied", .{k});
            },
            .baselined => baselined += 1,
            .already => {},
        }
    }
    if (baselined > 0) std.log.info("recorded the checksums of {d} migration(s) applied before Spider kept them", .{baselined});
    return applied;
}

const Outcome = enum { ran, baselined, already };

fn applyInTransaction(arena: std.mem.Allocator, k: []const u8, sum: *const [spider.migration.checksum_len]u8, statements: []const []const u8) !Outcome {
    var tx = try pg.begin();
    defer tx.rollback();
    try tx.query(void, arena, lock_sql, .{});
    if (try tx.queryOne(struct { checksum: ?[]const u8 }, arena, recorded_sql, .{k})) |row| {
        const outcome = try alreadyRecorded(k, row.checksum, sum);
        if (outcome == .baselined) {
            try tx.query(void, arena, baseline_sql, .{ k, @as([]const u8, sum) });
            try tx.commit();
        }
        return outcome;
    }
    for (statements) |stmt| {
        _ = tx.conn.exec(stmt, .{}) catch |err| {
            const typed = pg.fail(tx.conn, err);
            std.log.err("migration {s} failed: {s}", .{ k, @errorName(typed) });
            return typed;
        };
    }
    try tx.query(void, arena, insert_sql, .{ k, @as([]const u8, sum) });
    try tx.commit();
    return .ran;
}

fn applyAlone(arena: std.mem.Allocator, k: []const u8, sum: *const [spider.migration.checksum_len]u8, statement: []const u8) !Outcome {
    const conn = try pg.acquireConn();
    defer pg.releaseConn(conn);
    try pg.queryOn(conn, void, arena, session_lock_sql, .{});
    defer pg.queryOn(conn, void, arena, session_unlock_sql, .{}) catch {};
    if (try pg.queryOneOn(conn, struct { checksum: ?[]const u8 }, arena, recorded_sql, .{k})) |row| {
        const outcome = try alreadyRecorded(k, row.checksum, sum);
        if (outcome == .baselined) try pg.queryOn(conn, void, arena, baseline_sql, .{ k, @as([]const u8, sum) });
        return outcome;
    }
    _ = conn.exec(statement, .{}) catch |err| {
        const typed = pg.fail(conn, err);
        std.log.err("migration {s} failed: {s}", .{ k, @errorName(typed) });
        return typed;
    };
    try pg.queryOn(conn, void, arena, insert_sql, .{ k, @as([]const u8, sum) });
    return .ran;
}

/// A step whose row exists: unchanged, to be baselined (no checksum yet),
/// or error.MigrationChanged.
fn alreadyRecorded(k: []const u8, recorded: ?[]const u8, sum: *const [spider.migration.checksum_len]u8) !Outcome {
    const was = recorded orelse return .baselined;
    if (std.mem.eql(u8, was, sum)) return .already;
    std.log.err("migration {s} changed after it was applied (checksum {s}, now {s}): add a new migration instead of editing an applied one", .{ k, was, sum });
    return error.MigrationChanged;
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

test "migrations: the app's own, by bare name; a BEGIN ... COMMIT wrapper is left out" {
    try initTestDb(std.testing.allocator);
    defer pg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const clean = struct {
        fn run(ar: std.mem.Allocator) void {
            pg.query(void, ar, "DROP TABLE IF EXISTS spidertest_f_t", .{}) catch {};
            pg.query(void, ar, "DELETE FROM schema_migrations WHERE version LIKE '999000000%_spidertest_f_%'", .{}) catch {};
        }
    }.run;
    defer clean(a);
    clean(a);

    const steps = [_]Step{
        .{ .module = "", .name = "9990000001_spidertest_f_create", .sql = "BEGIN;\nCREATE TABLE spidertest_f_t (id int);\nCOMMIT;\n" },
        .{ .module = "", .name = "9990000002_spidertest_f_fill", .sql = "INSERT INTO spidertest_f_t VALUES (1); INSERT INTO spidertest_f_t VALUES (2)" },
        .{ .module = "", .name = "9990000003_spidertest_f_note", .sql = "-- nothing to change: the table is reused\n" },
    };
    try std.testing.expectEqual(@as(usize, 3), try apply(a, &steps));
    try std.testing.expectEqualSlices(State, &.{ .applied, .applied, .applied }, try status(a, &steps));
    try std.testing.expectEqual(@as(i64, 2), try pg.query(i64, a, "SELECT count(*) FROM spidertest_f_t", .{}));
    try std.testing.expect((try pg.queryOne(struct { n: i64 }, a, "SELECT count(*) AS n FROM schema_migrations WHERE version = '9990000001_spidertest_f_create' AND checksum IS NOT NULL", .{})).?.n == 1);
}

test "migrations: transaction control inside an app's migration, not as its wrapper, is refused" {
    try initTestDb(std.testing.allocator);
    defer pg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const steps = [_]Step{.{ .module = "", .name = "9990000005_spidertest_g", .sql = "CREATE TABLE spidertest_g_t (id int); COMMIT; CREATE TABLE spidertest_g_u (id int)" }};
    try std.testing.expectError(error.MigrationHasTransactionControl, apply(a, &steps));
    try std.testing.expect((try pg.queryOne(struct { t: bool }, a, "SELECT to_regclass('spidertest_g_t') IS NULL AS t", .{})).?.t);
}

test "migrations: CREATE INDEX CONCURRENTLY runs alone, outside a transaction; not alone it is refused" {
    try initTestDb(std.testing.allocator);
    defer pg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    defer cleanUp(a, "spidertest_h", &.{"spidertest_h_t"});
    cleanUp(a, "spidertest_h", &.{"spidertest_h_t"});

    const together = [_]Step{.{ .module = "spidertest_h", .name = "0001_both", .sql = "CREATE TABLE spidertest_h_t (id int); CREATE INDEX CONCURRENTLY spidertest_h_i ON spidertest_h_t (id)" }};
    try std.testing.expectError(error.MigrationNotAlone, apply(a, &together));

    const steps = [_]Step{
        .{ .module = "spidertest_h", .name = "0001_table", .sql = "CREATE TABLE spidertest_h_t (id int)" },
        .{ .module = "spidertest_h", .name = "0002_index", .sql = "-- migrate:up\nCREATE INDEX CONCURRENTLY IF NOT EXISTS spidertest_h_i ON spidertest_h_t (id);\n" },
    };
    try std.testing.expectEqual(@as(usize, 2), try apply(a, &steps));
    try std.testing.expectEqual(@as(usize, 0), try apply(a, &steps));
    try std.testing.expectEqualSlices(State, &.{ .applied, .applied }, try status(a, &steps));
    try std.testing.expect((try pg.queryOne(struct { t: bool }, a, "SELECT to_regclass('spidertest_h_i') IS NOT NULL AS t", .{})).?.t);
}

test "migrations: rows from before checksums get theirs, and an edit is caught from then on" {
    try initTestDb(std.testing.allocator);
    defer pg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const clean = struct {
        fn run(ar: std.mem.Allocator) void {
            pg.query(void, ar, "DELETE FROM schema_migrations WHERE version = '9990000004_spidertest_i'", .{}) catch {};
        }
    }.run;
    defer clean(a);
    clean(a);
    try pg.query(void, a, table_ddl, .{});
    try pg.query(void, a, checksum_ddl, .{});
    try pg.query(void, a, "INSERT INTO schema_migrations (version) VALUES ('9990000004_spidertest_i')", .{});

    const v1 = [_]Step{.{ .module = "", .name = "9990000004_spidertest_i", .sql = "SELECT 1" }};
    try std.testing.expectEqual(@as(usize, 0), try apply(a, &v1)); // nothing runs again
    const sum = spider.migration.checksum("SELECT 1");
    try std.testing.expectEqualStrings(&sum, (try pg.queryOne(struct { checksum: []const u8 }, a, "SELECT checksum FROM schema_migrations WHERE version = '9990000004_spidertest_i'", .{})).?.checksum);
    const v2 = [_]Step{.{ .module = "", .name = "9990000004_spidertest_i", .sql = "SELECT 2" }};
    try std.testing.expectEqualSlices(State, &.{.changed}, try status(a, &v2));
    try std.testing.expectError(error.MigrationChanged, apply(a, &v2));
}

test "cannotRunInTransaction: the statements PostgreSQL refuses in a transaction block" {
    try std.testing.expect(cannotRunInTransaction("CREATE INDEX CONCURRENTLY i ON t (a)"));
    try std.testing.expect(cannotRunInTransaction("-- note\ncreate unique index concurrently i on t (a)"));
    try std.testing.expect(cannotRunInTransaction("DROP INDEX CONCURRENTLY IF EXISTS i"));
    try std.testing.expect(cannotRunInTransaction("REINDEX (VERBOSE) INDEX CONCURRENTLY i"));
    try std.testing.expect(cannotRunInTransaction("VACUUM ANALYZE t"));
    try std.testing.expect(cannotRunInTransaction("CREATE DATABASE d"));
    try std.testing.expect(cannotRunInTransaction("ALTER SYSTEM SET work_mem = '8MB'"));
    try std.testing.expect(!cannotRunInTransaction("CREATE INDEX i ON t (a)"));
    try std.testing.expect(!cannotRunInTransaction("REINDEX INDEX i"));
    try std.testing.expect(!cannotRunInTransaction("CREATE TABLE concurrently (id int)"));
}
