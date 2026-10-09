const std = @import("std");

/// A row of the users table.
pub const User = struct {
    id: i64,
    name: []const u8,
    email: []const u8,
    /// What spider.password.hash made of the password; never the password.
    password_hash: []const u8,
    /// What `.roles` on a route checks: "user", "admin", ...
    role: []const u8,
};

pub const Registration = struct {
    name: []const u8 = "",
    email: []const u8 = "",
    password: []const u8 = "",
};

pub const Credentials = struct {
    email: []const u8 = "",
    password: []const u8 = "",
};

pub const min_password = 8;
pub const max_name = 80;
pub const max_email = 254;

/// What is wrong with a registration, in words for the person, or null.
/// Expects the name and the email already trimmed (see `tidy`).
pub fn problem(r: Registration) ?[]const u8 {
    if (r.name.len == 0) return "Tell us your name.";
    if (r.name.len > max_name) return "That name is too long.";
    if (!looksLikeEmail(r.email)) return "That does not look like an email address.";
    if (r.password.len < min_password) return "Use a password of at least 8 characters.";
    if (r.password.len > 200) return "That password is too long.";
    return null;
}

/// The name without the spaces around it and the email as it is stored:
/// trimmed and in lower case, so Ana@Example.com and ana@example.com are
/// one account.
pub fn tidy(arena: std.mem.Allocator, r: Registration) !Registration {
    return .{
        .name = std.mem.trim(u8, r.name, " \t\r\n"),
        .email = try tidyEmail(arena, r.email),
        .password = r.password,
    };
}

pub fn tidyEmail(arena: std.mem.Allocator, email: []const u8) ![]const u8 {
    return std.ascii.allocLowerString(arena, std.mem.trim(u8, email, " \t\r\n"));
}

fn looksLikeEmail(email: []const u8) bool {
    if (email.len > max_email) return false;
    const at = std.mem.indexOfScalar(u8, email, '@') orelse return false;
    if (at == 0 or std.mem.lastIndexOfScalar(u8, email, '@').? != at) return false;
    const domain = email[at + 1 ..];
    const dot = std.mem.lastIndexOfScalar(u8, domain, '.') orelse return false;
    if (dot == 0 or dot == domain.len - 1) return false;
    return std.mem.indexOfAny(u8, email, " \t\r\n") == null;
}

test "problem: a complete registration has none" {
    try std.testing.expect(problem(.{ .name = "Ana", .email = "ana@example.com", .password = "long enough" }) == null);
}

test "problem: names what is missing or wrong" {
    try std.testing.expectEqualStrings("Tell us your name.", problem(.{ .email = "a@b.co", .password = "12345678" }).?);
    try std.testing.expectEqualStrings("That does not look like an email address.", problem(.{ .name = "Ana", .email = "ana", .password = "12345678" }).?);
    try std.testing.expectEqualStrings("Use a password of at least 8 characters.", problem(.{ .name = "Ana", .email = "a@b.co", .password = "1234567" }).?);
    for ([_][]const u8{ "", "@b.co", "a@", "a@b", "a@.co", "a@b.", "a b@c.co", "a@@b.co" }) |bad| {
        try std.testing.expect(problem(.{ .name = "Ana", .email = bad, .password = "12345678" }) != null);
    }
}

test "tidy: trims the name, lowers the email, leaves the password alone" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try tidy(arena.allocator(), .{ .name = "  Ana  ", .email = " Ana@Example.COM ", .password = " Secret " });
    try std.testing.expectEqualStrings("Ana", r.name);
    try std.testing.expectEqualStrings("ana@example.com", r.email);
    try std.testing.expectEqualStrings(" Secret ", r.password);
}
