//! Internal: the shared strings table and the `xl/sharedStrings.xml` part.
//!
//! Text is not stored in the cell: the cell holds an index
//! (`<c t="s"><v>7</v></c>`) into one workbook-wide list of distinct
//! strings. This is what Excel itself writes, and every reader supports
//! it.

const std = @import("std");
const Writer = std.Io.Writer;
const xml = @import("xml.zig");

/// Every distinct text a workbook was given, numbered in the order it
/// was first seen.
pub const Table = struct {
    strings: std.ArrayList([]const u8) = .empty,
    ids: std.StringHashMapUnmanaged(u32) = .empty,

    /// Returns the id of `text`, copying it into `arena` if it is new.
    pub fn intern(self: *Table, arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!u32 {
        if (self.ids.get(text)) |id| return id;
        const owned = try arena.dupe(u8, text);
        const id: u32 = @intCast(self.strings.items.len);
        try self.strings.append(arena, owned);
        try self.ids.put(arena, owned, id);
        return id;
    }

    pub fn get(self: *const Table, id: u32) []const u8 {
        return self.strings.items[id];
    }

    pub fn count(self: *const Table) usize {
        return self.strings.items.len;
    }
};

/// Writes `xl/sharedStrings.xml`. `strings` is the list in file order
/// (a cell's `<v>` is an index into it) and `reference_count` is how
/// many cells point into it.
pub fn write(w: *Writer, strings: []const []const u8, reference_count: u64) Writer.Error!void {
    try w.writeAll(xml.declaration);
    try w.print(
        "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"{d}\" uniqueCount=\"{d}\">",
        .{ reference_count, strings.len },
    );
    for (strings) |text| {
        try w.writeAll(if (xml.needsSpacePreserve(text)) "<si><t xml:space=\"preserve\">" else "<si><t>");
        try xml.writeCellText(w, text);
        try w.writeAll("</t></si>");
    }
    try w.writeAll("</sst>");
}

const testing = std.testing;

test "equal texts share an id, in first-seen order" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var table: Table = .{};

    try testing.expectEqual(@as(u32, 0), try table.intern(arena, "Sim"));
    try testing.expectEqual(@as(u32, 1), try table.intern(arena, "Não"));
    try testing.expectEqual(@as(u32, 0), try table.intern(arena, "Sim"));
    try testing.expectEqual(@as(u32, 2), try table.intern(arena, ""));
    try testing.expectEqual(@as(u32, 3), try table.intern(arena, "sim"));
    try testing.expectEqual(@as(usize, 4), table.count());
    try testing.expectEqualStrings("Não", table.get(1));

    // The table keeps its own copy.
    var buffer: [4]u8 = "Nulo".*;
    const id = try table.intern(arena, &buffer);
    buffer[0] = 'X';
    try testing.expectEqualStrings("Nulo", table.get(id));
}

test "sharedStrings.xml" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, &.{ "Opção A", " padded ", "a < b & c", "=SUM(A1:A9)", "tab\there\r" }, 9);
    try testing.expectEqualStrings(xml.declaration ++
        "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"9\" uniqueCount=\"5\">" ++
        "<si><t>Opção A</t></si>" ++
        "<si><t xml:space=\"preserve\"> padded </t></si>" ++
        "<si><t>a &lt; b &amp; c</t></si>" ++
        "<si><t>=SUM(A1:A9)</t></si>" ++
        "<si><t xml:space=\"preserve\">tab\there_x000D_</t></si>" ++
        "</sst>", out.written());
}

test "sharedStrings.xml with no strings" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, &.{}, 0);
    try testing.expectEqualStrings(xml.declaration ++
        "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"0\" uniqueCount=\"0\"></sst>", out.written());
}
