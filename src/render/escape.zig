//! Internal: HTML escaping of text and quoted attribute values, used by the
//! interpreter (`renderer.appendEscaped`) and by compiled templates
//! (`elroy/runtime.escaped`). The five characters that matter in HTML text
//! and in single- or double-quoted attributes are replaced: `&` `<` `>` `"`
//! `'`. Everything else is copied as it is.
//!
//! Most text has few of them, so the search for the next one looks at 16
//! bytes at a time and the run before it is copied in one piece; a run of
//! consecutive specials is written from a table without searching again.
//! The bytes produced are the same as a byte-by-byte replacement (the tests
//! check it against one).

const std = @import("std");

/// The entity for each byte, or "" when the byte is written as it is.
const entities: [256][]const u8 = blk: {
    var t: [256][]const u8 = @splat("");
    t['&'] = "&amp;";
    t['<'] = "&lt;";
    t['>'] = "&gt;";
    t['"'] = "&quot;";
    t['\''] = "&#39;";
    break :blk t;
};

const lanes = 16;
const Chunk = @Vector(lanes, u8);
const Mask = u16; // one bit per lane

fn eqMask(chunk: Chunk, comptime ch: u8) Mask {
    return @bitCast(chunk == @as(Chunk, @splat(ch)));
}

/// The index of the first byte at or after `from` to escape, or `s.len`.
fn nextSpecial(s: []const u8, from: usize) usize {
    var i = from;
    while (i + lanes <= s.len) : (i += lanes) {
        const chunk: Chunk = s[i..][0..lanes].*;
        const mask = eqMask(chunk, '&') | eqMask(chunk, '<') | eqMask(chunk, '>') | eqMask(chunk, '"') | eqMask(chunk, '\'');
        if (mask != 0) return i + @ctz(mask);
    }
    while (i < s.len) : (i += 1) {
        if (entities[s[i]].len != 0) return i;
    }
    return s.len;
}

/// Writes `s` escaped to `w`.
pub fn write(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    var start: usize = 0;
    var i = nextSpecial(s, 0);
    while (i < s.len) {
        try w.writeAll(s[start..i]);
        while (i < s.len and entities[s[i]].len != 0) : (i += 1) try w.writeAll(entities[s[i]]);
        start = i;
        i = nextSpecial(s, i);
    }
    try w.writeAll(s[start..]);
}

/// Appends `s` escaped to `out`.
pub fn append(alc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) std.mem.Allocator.Error!void {
    var start: usize = 0;
    var i = nextSpecial(s, 0);
    while (i < s.len) {
        try out.appendSlice(alc, s[start..i]);
        while (i < s.len and entities[s[i]].len != 0) : (i += 1) try out.appendSlice(alc, entities[s[i]]);
        start = i;
        i = nextSpecial(s, i);
    }
    try out.appendSlice(alc, s[start..]);
}

const testing = std.testing;

/// The byte-by-byte replacement both functions must match.
fn reference(alc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| switch (ch) {
        '&' => try out.appendSlice(alc, "&amp;"),
        '<' => try out.appendSlice(alc, "&lt;"),
        '>' => try out.appendSlice(alc, "&gt;"),
        '"' => try out.appendSlice(alc, "&quot;"),
        '\'' => try out.appendSlice(alc, "&#39;"),
        else => try out.append(alc, ch),
    };
    return out.items;
}

fn expectSame(alc: std.mem.Allocator, s: []const u8) !void {
    const want = try reference(alc, s);
    var appended: std.ArrayList(u8) = .empty;
    try append(alc, &appended, s);
    try testing.expectEqualSlices(u8, want, appended.items);
    var written: std.Io.Writer.Allocating = .init(alc);
    try write(&written.writer, s);
    try testing.expectEqualSlices(u8, want, written.written());
}

test "escape: the five characters, and nothing else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    try append(a, &out, "<a href=\"x\">Tom & Jerry's</a> café");
    try testing.expectEqualStrings("&lt;a href=&quot;x&quot;&gt;Tom &amp; Jerry&#39;s&lt;/a&gt; café", out.items);
}

test "escape: every byte value, alone and at every position of a 16-byte chunk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..256) |b| {
        try expectSame(a, &.{@intCast(b)});
        // The byte at each offset of a run longer than one vector, so the
        // vector path, its tail and the boundary between them are all hit.
        for (0..40) |pos| {
            var buf: [40]u8 = @splat('x');
            buf[pos] = @intCast(b);
            try expectSame(a, &buf);
        }
    }
}

test "escape: random text full of specials matches the byte-by-byte replacement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    const alphabet = "&<>\"'abcdefghij ÿé\x00\x7f";
    var buf: [300]u8 = undefined;
    for (0..20_000) |_| {
        const len = r.uintLessThan(usize, buf.len + 1);
        for (buf[0..len]) |*ch| ch.* = if (r.boolean()) alphabet[r.uintLessThan(usize, alphabet.len)] else r.int(u8);
        try expectSame(a, buf[0..len]);
    }
    try expectSame(a, "");
}
