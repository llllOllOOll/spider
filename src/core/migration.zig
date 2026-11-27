//! A database migration (`spider.Migration`), a module's or the app's own,
//! and the rules for its name, its key in `schema_migrations`, the part of
//! its file that runs and its checksum. No database here:
//! `spider.pg.migrations` applies them and reads their state.
//!
//! Standalone on purpose (std only): the pg module's tests build it without
//! the rest of Spider.

const std = @import("std");

/// One forward migration: a name and the SQL it runs. A module lists its
/// own in its manifest; an app's come from its migrations folder
/// (`spider.addMigrations` in build.zig, then `server.migrations(...)`).
///
/// The name is four or more digits, `_`, then lowercase letters, digits and
/// `_` (`0001_init`); names sort in the order they run. The SQL may hold
/// several statements; it runs in one transaction that Spider opens, so it
/// must not contain BEGIN, COMMIT or ROLLBACK. When the file has a
/// `-- migrate:up` line, only what follows it runs, up to `-- migrate:down`.
///
/// ```zig
/// .migrations = .{
///     .{ .name = "0001_init", .sql = @embedFile("sql/0001_init.sql") },
/// },
/// ```
pub const Migration = struct {
    /// `0001_init`: ordering digits, `_`, a lowercase description.
    name: []const u8,
    /// The statements, PostgreSQL. Runs inside a transaction.
    sql: []const u8,
};

// internal: one migration to apply or look up, with the module it belongs
// to, "" for the app's own (spider.pg.migrations works on these). `sql` is
// what runs: the `-- migrate:up` part of the file (see upSection).
pub const Step = struct {
    module: []const u8,
    name: []const u8,
    sql: []const u8,

    // internal: whether this is one of the app's own migrations.
    pub fn ofApp(self: Step) bool {
        return self.module.len == 0;
    }
};

// internal: where a step stands in the database.
pub const State = enum {
    /// Not recorded in schema_migrations.
    pending,
    /// Recorded, with the same checksum (or with none, from before checksums).
    applied,
    /// Recorded with a different checksum: the SQL was edited after it ran.
    changed,
};

// internal: why a migration name is refused, or null when it is valid.
pub fn nameProblem(name: []const u8) ?[]const u8 {
    var digits: usize = 0;
    while (digits < name.len and std.ascii.isDigit(name[digits])) digits += 1;
    if (digits < 4) return "starts with fewer than four digits";
    if (digits == name.len or name[digits] != '_') return "has no `_` after its digits";
    const rest = name[digits + 1 ..];
    if (rest.len == 0) return "has nothing after the `_`";
    for (rest) |ch| {
        if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_')) return "may only hold lowercase letters, digits and `_` after the digits";
    }
    return null;
}

// internal: why a list of migrations is refused (a name, the order, the
// SQL), or null when every one is valid. `name` is printed at the start.
// The comptime branch budget follows the list: each migration adds
// what its checks can cost (`checkBranches`), so a long list or a long
// file never exhausts a fixed quota.
pub fn listProblem(comptime owner: []const u8, comptime list: []const Migration) ?[]const u8 {
    var quota: u32 = 10_000;
    for (list, 0..) |m, i| {
        quota +|= checkBranches(m.sql.len);
        @setEvalBranchQuota(quota);
        if (nameProblem(m.name)) |p| return std.fmt.comptimePrint("{s}: migration \"{s}\" {s}", .{ owner, m.name, p });
        if (std.mem.trim(u8, upSection(m.sql), " \t\r\n").len == 0) return std.fmt.comptimePrint("{s}: migration \"{s}\" has no SQL", .{ owner, m.name });
        if (i > 0 and !std.mem.lessThan(u8, list[i - 1].name, m.name))
            return std.fmt.comptimePrint("{s}: migration \"{s}\" must come after \"{s}\" (names in increasing order, each once)", .{ owner, list[i - 1].name, m.name });
    }
    return null;
}

// internal: the part of a migration file that runs: what follows a
// `-- migrate:up` line (from the start when there is none: a module's files
// have none), up to a `-- migrate:down` line (to the end when there is
// none). The down part never runs. One pass over the file: listProblem
// runs it at compile time on every migration (see checkBranches).
pub fn upSection(sql: []const u8) []const u8 {
    const up = "-- migrate:up";
    const down = "-- migrate:down";
    // Where the line after the up line begins, once it is found.
    var body: ?usize = null;
    // The first down line, for a file without an up line.
    var first_down: ?usize = null;
    var begin: usize = 0;
    while (begin < sql.len) {
        var end = begin;
        while (end < sql.len and sql[end] != '\n') end += 1;
        const next = if (end < sql.len) end + 1 else end;
        if (sql[begin] == '-') {
            const line = std.mem.trimEnd(u8, sql[begin..end], " \t\r");
            if (body == null and std.mem.eql(u8, line, up)) {
                body = next;
            } else if (std.mem.eql(u8, line, down)) {
                if (body) |b| return sql[b..begin];
                if (first_down == null) first_down = begin;
            }
        }
        begin = next;
    }
    if (body) |b| return sql[b..];
    return sql[0 .. first_down orelse sql.len];
}

// internal: the comptime branches the checks of one migration may take
// (its name, its order, and upSection plus the trim on `sql_len` bytes).
// A file of empty lines is the worst case, at about eight per byte: 16
// leaves room. Callers that check migrations at compile time raise their
// quota by this much per migration.
pub fn checkBranches(sql_len: usize) u32 {
    const per_byte = 16;
    const per_migration = 1_000;
    const n = std.math.cast(u32, sql_len) orelse return std.math.maxInt(u32);
    return per_migration +| n *| per_byte;
}

// internal: the separator between a module and a migration in the key.
pub const key_separator = '/';

// internal: the key of a migration in `schema_migrations.version`:
// `module/name` for a module's, the bare name for the app's own (`""`
// module), as `spider migrate` has always recorded its files. A name never
// holds a `/`, so the two never collide.
pub fn key(allocator: std.mem.Allocator, module: []const u8, name: []const u8) ![]u8 {
    if (module.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ module, key_separator, name });
}

// internal: the length of a checksum, in hex characters.
pub const checksum_len = 64;

// internal: the SHA-256 of a migration's SQL, in lowercase hex. Recorded
// when it runs; a different checksum later means the file changed after it
// was applied.
pub fn checksum(sql: []const u8) [checksum_len]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(sql, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "nameProblem: digits, an underscore and a lowercase description" {
    try std.testing.expect(nameProblem("0001_init") == null);
    try std.testing.expect(nameProblem("20261018_add_inbox_2") == null);
    try std.testing.expect(nameProblem("001_init") != null);
    try std.testing.expect(nameProblem("0001init") != null);
    try std.testing.expect(nameProblem("0001_") != null);
    try std.testing.expect(nameProblem("0001_Init") != null);
    try std.testing.expect(nameProblem("0001_in-it") != null);
}

test "key: module and name for a module, the bare name for the app" {
    const k = try key(std.testing.allocator, "notify", "0001_init");
    defer std.testing.allocator.free(k);
    try std.testing.expectEqualStrings("notify/0001_init", k);
    const app = try key(std.testing.allocator, "", "1790800000_notify");
    defer std.testing.allocator.free(app);
    try std.testing.expectEqualStrings("1790800000_notify", app);
}

test "upSection: between the markers, or the whole file" {
    try std.testing.expectEqualStrings("CREATE TABLE t (id int);\n\n", upSection(
        \\-- a header
        \\-- migrate:up
        \\CREATE TABLE t (id int);
        \\
        \\-- migrate:down
        \\DROP TABLE t;
    ));
    try std.testing.expectEqualStrings("SELECT 1;\r\n", upSection("-- migrate:up  \r\nSELECT 1;\r\n-- migrate:down\r\nSELECT 2;"));
    try std.testing.expectEqualStrings("SELECT 1;", upSection("-- migrate:up\nSELECT 1;"));
    // No up line: from the start, still never the down part.
    try std.testing.expectEqualStrings("CREATE TABLE t (id int);\n\n", upSection("CREATE TABLE t (id int);\n\n-- migrate:down\nDROP TABLE t;\n"));
    try std.testing.expectEqualStrings("SELECT 1; -- migrate:up inside a line", upSection("SELECT 1; -- migrate:up inside a line"));
}

test "listProblem: valid names, in increasing order, each with SQL" {
    try std.testing.expect(comptime listProblem("app", &.{
        .{ .name = "1779927672_create_packages", .sql = "-- migrate:up\nCREATE TABLE p (id int);" },
        .{ .name = "1780900000_add_pin", .sql = "ALTER TABLE p ADD pin text;" },
    }) == null);
    try std.testing.expectEqualStrings("app: migration \"0002_b\" must come after \"0001_a\" (names in increasing order, each once)", comptime listProblem("app", &.{
        .{ .name = "0002_b", .sql = "SELECT 1" },
        .{ .name = "0001_a", .sql = "SELECT 1" },
    }).?);
    try std.testing.expectEqualStrings("app: migration \"0001_a\" has no SQL", comptime listProblem("app", &.{
        .{ .name = "0001_a", .sql = "-- migrate:up\n\n-- migrate:down\nDROP TABLE t;" },
    }).?);
    try std.testing.expect(comptime listProblem("app", &.{.{ .name = "1_a", .sql = "SELECT 1" }}) != null);
}

test "checksum: stable, and changes with the text" {
    const a = checksum("CREATE TABLE t (id int);");
    try std.testing.expectEqualStrings(&a, &checksum("CREATE TABLE t (id int);"));
    try std.testing.expect(!std.mem.eql(u8, &a, &checksum("CREATE TABLE t (id bigint);")));
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &checksum(""));
}
