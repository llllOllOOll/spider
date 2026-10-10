//! Password hashing for an app's own users.
//!
//! ```zig
//! const stored = try spider.password.hash(c, form.password); // save this
//! if (!spider.password.verify(c, user.password_hash, form.password)) ...
//! ```
//!
//! argon2id with the parameters OWASP recommends. The result is a PHC
//! string ("$argon2id$v=19$m=19456,t=2,p=1$<salt>$<hash>"): it carries its
//! own salt and parameters, so it goes into one text column and old hashes
//! keep verifying if the parameters change later.
const std = @import("std");
const Ctx = @import("../core/context.zig").Ctx;
const argon2 = std.crypto.pwhash.argon2;

/// The longest password accepted, in bytes. A longer one is refused before
/// any hashing (`hash`: `error.PasswordTooLong`; `verify`: false), so a
/// huge input costs the server nothing.
pub const max_len = 256;

/// What `hash` fails with: `error.PasswordTooLong` (over `max_len` bytes), out
/// of memory, or an error of the argon2 implementation.
pub const Error = error{PasswordTooLong} || std.mem.Allocator.Error || std.crypto.pwhash.Error;

/// The hash of `password`, to store. Allocated in the request arena.
pub fn hash(c: *Ctx, password: []const u8) Error![]const u8 {
    return hashWith(c.arena, c._io, password);
}

/// True when `password` is the one `stored` was made from. False for a
/// wrong password, for a `stored` value that is not a hash at all, and for
/// a password over `max_len` bytes.
pub fn verify(c: *Ctx, stored: []const u8, password: []const u8) bool {
    return verifyWith(c.arena, c._io, stored, password);
}

/// `hash` outside a request (a seed script, a test).
pub fn hashWith(arena: std.mem.Allocator, io: std.Io, password: []const u8) Error![]const u8 {
    if (password.len > max_len) return error.PasswordTooLong;
    var buf: [256]u8 = undefined;
    const phc = try argon2.strHash(password, .{ .allocator = arena, .params = .owasp_2id }, &buf, io);
    return arena.dupe(u8, phc);
}

/// `verify` outside a request.
pub fn verifyWith(arena: std.mem.Allocator, io: std.Io, stored: []const u8, password: []const u8) bool {
    if (password.len > max_len) return false;
    argon2.strVerify(stored, password, .{ .allocator = arena }, io) catch return false;
    return true;
}

/// A hash of nothing in particular. Verify a login against it when the
/// account does not exist, so a missing account takes as long to refuse as
/// a wrong password.
pub const decoy = "$argon2id$v=19$m=19456,t=2,p=1$c3BpZGVyLWRlY295LXNhbHQ$Y0rqCIYQxkoy1vQpTVV2Rk0vY0V1hYp8X8jJmJq1x0o";

test "hash then verify; a wrong password and a broken hash are refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    const stored = try hashWith(a, io, "correct horse battery staple");
    try std.testing.expect(std.mem.startsWith(u8, stored, "$argon2id$v=19$m=19456,t=2,p=1$"));
    try std.testing.expect(verifyWith(a, io, stored, "correct horse battery staple"));
    try std.testing.expect(!verifyWith(a, io, stored, "correct horse battery stapl"));
    try std.testing.expect(!verifyWith(a, io, "not a hash", "x"));
    try std.testing.expect(!verifyWith(a, io, "", ""));
}

test "the same password hashes differently each time (its own salt)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try hashWith(a, std.testing.io, "secret-123");
    const two = try hashWith(a, std.testing.io, "secret-123");
    try std.testing.expect(!std.mem.eql(u8, one, two));
}

test "a password over the limit is refused, and never matches" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const long: [max_len + 1]u8 = @splat('a');
    try std.testing.expectError(error.PasswordTooLong, hashWith(arena.allocator(), std.testing.io, &long));
    try std.testing.expect(!verifyWith(arena.allocator(), std.testing.io, decoy, &long));
}

test "the decoy is a well-formed hash that matches no password" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(!verifyWith(arena.allocator(), std.testing.io, decoy, "anything"));
    // Well-formed: it fails on the comparison, after doing the work.
    try std.testing.expectError(error.PasswordVerificationFailed, argon2.strVerify(decoy, "anything", .{ .allocator = arena.allocator() }, std.testing.io));
}
