//! Internal: the rule behind `zig build test`'s documentation check. Every
//! `pub` name of the library says which side it is on: a `///` above it
//! (API of an app, shown in the reference) or a `// internal: why` comment
//! (public only for Spider's own files). A file whose `//!` header has a
//! line starting with `Internal:` is internal as a whole.
//!
//! It reads the source as text, line by line: enough for code that went
//! through `zig fmt`.

const std = @import("std");

pub const Kind = enum { api, internal, unclassified };

/// The name declared by a `pub fn`, `pub const` or `pub var` line, or null
/// when the line declares none.
pub fn pubName(line: []const u8) ?[]const u8 {
    var rest = std.mem.trimStart(u8, line, " ");
    if (!std.mem.startsWith(u8, rest, "pub ")) return null;
    rest = rest[4..];
    if (std.mem.startsWith(u8, rest, "inline ")) rest = rest[7..];
    inline for (.{ "fn ", "const ", "var " }) |word| {
        if (std.mem.startsWith(u8, rest, word)) {
            const name = rest[word.len..];
            var end: usize = 0;
            if (name.len > 1 and name[0] == '@' and name[1] == '"') {
                end = (std.mem.indexOfScalarPos(u8, name, 2, '"') orelse return null) + 1;
            } else {
                while (end < name.len and (std.ascii.isAlphanumeric(name[end]) or name[end] == '_')) end += 1;
            }
            return if (end == 0) null else name[0..end];
        }
    }
    return null;
}

/// True when the file's `//!` header declares the whole file internal.
pub fn fileIsInternal(lines: []const []const u8) bool {
    for (lines) |line| {
        if (!std.mem.startsWith(u8, line, "//!")) return false;
        if (std.mem.startsWith(u8, line, "//! Internal:")) return true;
    }
    return false;
}

pub fn hasHeader(lines: []const []const u8) bool {
    return lines.len > 0 and std.mem.startsWith(u8, lines[0], "//!");
}

fn indentOf(line: []const u8) usize {
    return line.len - std.mem.trimStart(u8, line, " ").len;
}

fn isComment(line: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "//");
}

/// What the comment right above line `i` says about it.
pub fn kindAt(lines: []const []const u8, i: usize) Kind {
    if (i == 0) return .unclassified;
    var j = i - 1;
    const above = std.mem.trimStart(u8, lines[j], " ");
    if (std.mem.startsWith(u8, above, "///")) return .api;
    // A plain comment block: internal when one of its lines says so.
    while (true) {
        const text = std.mem.trimStart(u8, lines[j], " ");
        if (!std.mem.startsWith(u8, text, "//") or std.mem.startsWith(u8, text, "///")) break;
        if (std.mem.startsWith(u8, text, "// internal:")) return .internal;
        if (j == 0) break;
        j -= 1;
    }
    return .unclassified;
}

/// The line that opens the block line `i` is in, or null at the top level.
fn containerOf(lines: []const []const u8, i: usize) ?usize {
    const indent = indentOf(lines[i]);
    if (indent == 0) return null;
    var j = i;
    while (j > 0) {
        j -= 1;
        const line = lines[j];
        if (std.mem.trim(u8, line, " ").len == 0 or isComment(line)) continue;
        if (indentOf(line) < indent and std.mem.endsWith(u8, std.mem.trimEnd(u8, line, " "), "{")) return j;
    }
    return null;
}

/// False for a `pub` name an app cannot reach as API: nested in something
/// that is not public (a private type, a function body), or in a name
/// marked internal.
pub fn reachable(lines: []const []const u8, i: usize) bool {
    var at = i;
    while (containerOf(lines, at)) |c| {
        const text = std.mem.trimStart(u8, lines[c], " ");
        if (pubName(lines[c]) != null) {
            if (kindAt(lines, c) == .internal) return false;
        } else if (!std.mem.startsWith(u8, text, "return struct") and
            !std.mem.startsWith(u8, text, "return extern struct") and
            !std.mem.startsWith(u8, text, "return packed struct") and
            !std.mem.startsWith(u8, text, "return union") and
            !std.mem.startsWith(u8, text, "return enum"))
        {
            return false;
        }
        at = c;
    }
    return true;
}

pub const Problem = struct { line: usize, name: []const u8 };

/// The `pub` names of a file that say neither `///` nor `// internal:`.
/// Lines count from 1. The result lives in `arena`.
pub fn unclassified(arena: std.mem.Allocator, source: []const u8) ![]Problem {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| try lines.append(arena, line);

    var out: std.ArrayList(Problem) = .empty;
    if (fileIsInternal(lines.items)) return out.items;
    for (lines.items, 0..) |line, i| {
        const name = pubName(line) orelse continue;
        if (!reachable(lines.items, i)) continue;
        if (kindAt(lines.items, i) == .unclassified) try out.append(arena, .{ .line = i + 1, .name = name });
    }
    return out.items;
}

fn expectProblems(source: []const u8, names: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const found = try unclassified(arena.allocator(), source);
    try std.testing.expectEqual(names.len, found.len);
    for (names, found) |want, got| try std.testing.expectEqualStrings(want, got.name);
}

test "doc check: a pub name needs a doc comment or an internal note" {
    try expectProblems(
        \\/// Documented.
        \\pub fn a() void {}
        \\// internal: the server calls it.
        \\pub fn b() void {}
        \\// just a remark
        \\pub fn c() void {}
        \\pub const d = 1;
        \\fn private() void {}
    , &.{ "c", "d" });
}

test "doc check: an internal note may be the first line of a longer comment" {
    try expectProblems(
        \\// internal: the old handle;
        \\// apps use something else.
        \\pub fn a() void {}
    , &.{});
}

test "doc check: methods of a public type count, those of an internal or private one do not" {
    try expectProblems(
        \\/// A type.
        \\pub const T = struct {
        \\    /// Documented.
        \\    pub fn a() void {}
        \\    pub fn b() void {}
        \\};
        \\// internal: plumbing.
        \\pub const U = struct {
        \\    pub fn c() void {}
        \\};
        \\const V = struct {
        \\    pub fn d() void {}
        \\};
        \\fn f() void {
        \\    const W = struct {
        \\        pub fn call() void {}
        \\    };
        \\    _ = W;
        \\}
    , &.{"b"});
}

test "doc check: a type returned by a public function is part of it" {
    try expectProblems(
        \\/// Makes a type.
        \\pub fn Make(comptime T: type) type {
        \\    return struct {
        \\        pub fn a(_: T) void {}
        \\    };
        \\}
    , &.{"a"});
}

test "doc check: a file whose header says Internal is skipped" {
    try expectProblems(
        \\//! Internal: plumbing of the router.
        \\
        \\pub fn a() void {}
    , &.{});
    try expectProblems(
        \\//! What this file is for.
        \\
        \\pub fn a() void {}
    , &.{"a"});
}

test "doc check: pubName" {
    try std.testing.expectEqualStrings("get", pubName("    pub fn get(self: *Self) void {").?);
    try std.testing.expectEqualStrings("@\"inline\"", pubName("pub const @\"inline\" = 1;").?);
    try std.testing.expectEqualStrings("x", pubName("pub inline fn x() void {}").?);
    try std.testing.expect(pubName("fn get() void {}") == null);
    try std.testing.expect(pubName("// pub fn get() void {}") == null);
}
