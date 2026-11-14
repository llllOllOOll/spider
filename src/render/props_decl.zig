//! Internal: a component's declared props, from an optional first line:
//!
//!     -- props: id!, title!, year: int, finished: bool = false, size = "md"
//!
//! `!` marks a required prop; `: string|int|bool` a type; `= value` a
//! default (a quoted string, a number, true or false). A component without
//! the line declares nothing and works as before. The parser skips the line;
//! the renderer and `spider check` read it here.

const std = @import("std");

pub const header = "-- props:";

pub const Kind = enum { any, string, int, bool };

pub const Prop = struct {
    name: []const u8,
    required: bool = false,
    kind: Kind = .any,
    /// The default as written, quotes removed for a string.
    default: ?[]const u8 = null,

    /// True when the literal `text` (a prop written `name="text"`) is a
    /// value of this prop's type.
    pub fn accepts(self: Prop, text: []const u8) bool {
        return switch (self.kind) {
            .any, .string => true,
            .int => blk: {
                _ = std.fmt.parseInt(i64, text, 10) catch break :blk false;
                break :blk true;
            },
            .bool => std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false"),
        };
    }
};

pub const Decl = struct {
    props: []const Prop,

    pub fn get(self: Decl, name: []const u8) ?Prop {
        for (self.props) |p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }

    /// "a, b, c", for messages.
    pub fn names(self: Decl, alc: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.props, 0..) |p, i| {
            if (i > 0) try out.appendSlice(alc, ", ");
            try out.appendSlice(alc, p.name);
        }
        return out.toOwnedSlice(alc);
    }
};

pub const Error = error{ InvalidPropsHeader, OutOfMemory };

/// The declaration at the start of `src`, or null when there is none.
/// Leading blank lines are allowed before it. The strings point into `src`.
pub fn parse(alc: std.mem.Allocator, src: []const u8) Error!?Decl {
    const line = headerLine(src) orelse return null;
    var props: std.ArrayList(Prop) = .empty;
    var items = std.mem.splitScalar(u8, line[header.len..], ',');
    while (items.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t\r");
        if (item.len == 0) continue;
        var p: Prop = .{ .name = "" };
        var rest = item;
        if (std.mem.indexOfScalar(u8, rest, '=')) |eq| {
            var def = std.mem.trim(u8, rest[eq + 1 ..], " ");
            if (def.len >= 2 and def[0] == '"' and def[def.len - 1] == '"') def = def[1 .. def.len - 1];
            p.default = def;
            rest = std.mem.trim(u8, rest[0..eq], " ");
        }
        if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
            const kind = std.mem.trim(u8, rest[colon + 1 ..], " ");
            p.kind = std.meta.stringToEnum(Kind, kind) orelse return error.InvalidPropsHeader;
            rest = std.mem.trim(u8, rest[0..colon], " ");
        }
        if (std.mem.endsWith(u8, rest, "!")) {
            p.required = true;
            rest = rest[0 .. rest.len - 1];
        }
        if (rest.len == 0) return error.InvalidPropsHeader;
        for (rest) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return error.InvalidPropsHeader;
        p.name = rest;
        if (p.default) |d| if (!p.accepts(d)) return error.InvalidPropsHeader;
        try props.append(alc, p);
    }
    return .{ .props = try props.toOwnedSlice(alc) };
}

/// The `-- props:` line (without its newline), or null.
pub fn headerLine(src: []const u8) ?[]const u8 {
    const start = std.mem.indexOfNone(u8, src, " \t\r\n") orelse return null;
    if (!std.mem.startsWith(u8, src[start..], header)) return null;
    const end = std.mem.indexOfScalarPos(u8, src, start, '\n') orelse src.len;
    return std.mem.trimEnd(u8, src[start..end], "\r");
}

/// Where the template continues after the header line (0 without one).
pub fn bodyStart(src: []const u8) usize {
    const line = headerLine(src) orelse return 0;
    const end = @intFromPtr(line.ptr) - @intFromPtr(src.ptr) + line.len;
    return if (end < src.len and src[end] == '\n') end + 1 else end;
}

const t = std.testing;

test "parse: required, typed, defaults; none without the line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = (try parse(a, "\n-- props: id!, title!, year: int, finished: bool = false, size = \"md\"\n<b>{ title }</b>")).?;
    try t.expectEqual(@as(usize, 5), d.props.len);
    try t.expect(d.get("id").?.required);
    try t.expectEqual(Kind.int, d.get("year").?.kind);
    try t.expectEqualStrings("false", d.get("finished").?.default.?);
    try t.expectEqualStrings("md", d.get("size").?.default.?);
    try t.expect(!d.get("size").?.required);
    try t.expect(d.get("nope") == null);
    try t.expect((try parse(a, "<b>no header</b>")) == null);
    try t.expectEqualStrings("<b>{ title }</b>", ("\n-- props: id!, title!, year: int, finished: bool = false, size = \"md\"\n<b>{ title }</b>")[bodyStart("\n-- props: id!, title!, year: int, finished: bool = false, size = \"md\"\n<b>{ title }</b>")..]);
}

test "parse: a header that does not make sense is an error" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.InvalidPropsHeader, parse(arena.allocator(), "-- props: year: float"));
    try t.expectError(error.InvalidPropsHeader, parse(arena.allocator(), "-- props: year: int = abc"));
    try t.expectError(error.InvalidPropsHeader, parse(arena.allocator(), "-- props: !"));
    try t.expectError(error.InvalidPropsHeader, parse(arena.allocator(), "-- props: a-b"));
}

test "accepts: literal values by type" {
    const year: Prop = .{ .name = "year", .kind = .int };
    try t.expect(year.accepts("1969"));
    try t.expect(!year.accepts("1969x"));
    const done: Prop = .{ .name = "done", .kind = .bool };
    try t.expect(done.accepts("true") and done.accepts("false") and !done.accepts("yes"));
}
