//! Internal: version ranges, as modules declare the Spider versions they
//! support (`.spider = ">=0.11.0 <0.13.0"`). Works at compile time, which is
//! where `spider.module` checks a module against `spider.version`, and at
//! run time.
//!
//! A range is one to `max_comparators` comparators separated by spaces, all
//! of which must hold: `>=1.2.3`, `>1.2.3`, `<=1.2.3`, `<1.2.3`, `=1.2.3` or
//! a bare `1.2.3` (the same as `=`). Versions are full semver
//! (`major.minor.patch`, optional pre-release), compared by
//! `std.SemanticVersion.order`.

const std = @import("std");

// internal: how a comparator compares.
pub const Op = enum { eq, lt, le, gt, ge };

// internal: one `>=1.2.3` of a range.
pub const Comparator = struct {
    op: Op,
    version: std.SemanticVersion,

    // internal: whether `v` satisfies this comparator.
    pub fn holds(self: Comparator, v: std.SemanticVersion) bool {
        const o = v.order(self.version);
        return switch (self.op) {
            .eq => o == .eq,
            .lt => o == .lt,
            .le => o != .gt,
            .gt => o == .gt,
            .ge => o != .lt,
        };
    }
};

// internal: the most comparators one range holds.
pub const max_comparators = 4;

// internal: a parsed range. Fixed size, so it can live at compile time.
pub const Range = struct {
    items: [max_comparators]Comparator = undefined,
    len: usize = 0,

    // internal: whether `v` satisfies every comparator.
    pub fn contains(self: Range, v: std.SemanticVersion) bool {
        for (self.items[0..self.len]) |c| if (!c.holds(v)) return false;
        return true;
    }
};

// internal: why a range does not parse.
pub const ParseError = error{ EmptyRange, InvalidVersion, TooManyComparators };

// internal: parses a range; see the file's header for the syntax.
pub fn parseRange(text: []const u8) ParseError!Range {
    var r: Range = .{};
    var it = std.mem.tokenizeAny(u8, text, " \t");
    while (it.next()) |tok| {
        if (r.len == max_comparators) return error.TooManyComparators;
        const op: Op, const rest: []const u8 = if (std.mem.startsWith(u8, tok, ">="))
            .{ .ge, tok[2..] }
        else if (std.mem.startsWith(u8, tok, "<="))
            .{ .le, tok[2..] }
        else if (std.mem.startsWith(u8, tok, ">"))
            .{ .gt, tok[1..] }
        else if (std.mem.startsWith(u8, tok, "<"))
            .{ .lt, tok[1..] }
        else if (std.mem.startsWith(u8, tok, "="))
            .{ .eq, tok[1..] }
        else
            .{ .eq, tok };
        const v = std.SemanticVersion.parse(rest) catch return error.InvalidVersion;
        r.items[r.len] = .{ .op = op, .version = v };
        r.len += 1;
    }
    if (r.len == 0) return error.EmptyRange;
    return r;
}

fn sv(comptime s: []const u8) std.SemanticVersion {
    return std.SemanticVersion.parse(s) catch unreachable;
}

test "parseRange: a lower and an upper bound" {
    const r = try parseRange(">=0.11.0 <0.13.0");
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expect(!r.contains(sv("0.10.9")));
    try std.testing.expect(r.contains(sv("0.11.0")));
    try std.testing.expect(r.contains(sv("0.12.7")));
    try std.testing.expect(!r.contains(sv("0.13.0")));
}

test "parseRange: every operator, and a bare version is exact" {
    try std.testing.expect((try parseRange("1.2.3")).contains(sv("1.2.3")));
    try std.testing.expect(!(try parseRange("=1.2.3")).contains(sv("1.2.4")));
    try std.testing.expect((try parseRange(">1.2.3")).contains(sv("1.2.4")));
    try std.testing.expect(!(try parseRange(">1.2.3")).contains(sv("1.2.3")));
    try std.testing.expect((try parseRange("<=1.2.3")).contains(sv("1.2.3")));
    try std.testing.expect(!(try parseRange("<1.2.3")).contains(sv("1.2.3")));
}

test "parseRange: a pre-release sorts before its release" {
    const r = try parseRange(">=0.11.0");
    try std.testing.expect(!r.contains(sv("0.11.0-rc.1")));
    try std.testing.expect((try parseRange(">=0.11.0-rc.1")).contains(sv("0.11.0")));
}

test "parseRange: refusals" {
    try std.testing.expectError(error.EmptyRange, parseRange("  "));
    try std.testing.expectError(error.InvalidVersion, parseRange(">=0.11"));
    try std.testing.expectError(error.InvalidVersion, parseRange("^0.11.0"));
    try std.testing.expectError(error.TooManyComparators, parseRange("1.0.0 1.0.0 1.0.0 1.0.0 1.0.0"));
}

test "parseRange: works at compile time" {
    const r = comptime parseRange(">=0.10.0 <1.0.0") catch unreachable;
    comptime std.debug.assert(r.contains(sv("0.10.1")));
}
