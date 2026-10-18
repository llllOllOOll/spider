//! A database migration a module ships (`spider.Migration`), and the rules
//! for its name, its key in `schema_migrations` and its checksum. No
//! database here: `spider.pg.migrations` applies them and reads their state.
//!
//! Standalone on purpose (std only): the pg module's tests build it without
//! the rest of Spider.

const std = @import("std");

/// One forward migration of a module: a name and the SQL it runs.
///
/// The name is four or more digits, `_`, then lowercase letters, digits and
/// `_` (`0001_init`); names sort in the order they run. The SQL may hold
/// several statements; it runs in one transaction that Spider opens, so it
/// must not contain BEGIN, COMMIT or ROLLBACK.
///
/// ```zig
/// pub const migrations = [_]spider.Migration{
///     .{ .name = "0001_init", .sql = @embedFile("sql/0001_init.sql") },
/// };
/// ```
pub const Migration = struct {
    /// `0001_init`: ordering digits, `_`, a lowercase description.
    name: []const u8,
    /// The statements, PostgreSQL. Runs inside a transaction.
    sql: []const u8,
};

// internal: one migration to apply or look up, with the module it belongs
// to (spider.pg.migrations works on these).
pub const Step = struct {
    module: []const u8,
    name: []const u8,
    sql: []const u8,
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

// internal: the separator between a module and a migration in the key.
pub const key_separator = '/';

// internal: the key of a module's migration in `schema_migrations.version`:
// `module/name`. The app's own migrations are file names, which never hold
// a `/`, so the two never collide.
pub fn key(allocator: std.mem.Allocator, module: []const u8, name: []const u8) ![]u8 {
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

test "key: module and name, never a file name of the app" {
    const k = try key(std.testing.allocator, "notify", "0001_init");
    defer std.testing.allocator.free(k);
    try std.testing.expectEqualStrings("notify/0001_init", k);
}

test "checksum: stable, and changes with the text" {
    const a = checksum("CREATE TABLE t (id int);");
    try std.testing.expectEqualStrings(&a, &checksum("CREATE TABLE t (id int);"));
    try std.testing.expect(!std.mem.eql(u8, &a, &checksum("CREATE TABLE t (id bigint);")));
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &checksum(""));
}
