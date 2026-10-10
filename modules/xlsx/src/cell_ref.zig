//! Cell addresses. Rows and columns are zero-based everywhere in the
//! API; the file format uses A1 references (column letters, one-based
//! row).

const std = @import("std");
const Writer = std.Io.Writer;

/// Excel's sheet size: rows 0..1,048,575 and columns 0..16,383 (XFD).
pub const max_rows: u32 = 1_048_576;
/// Columns per sheet (A to XFD).
pub const max_cols: u32 = 16_384;

// internal: used inside the xlsx module; apps do not call it.
// Writes the letters of a zero-based column: 0 is `A`, 25 `Z`, 26
// `AA`, 16,383 `XFD`. `col` must be below `max_cols` (asserted).
pub fn writeColumnName(w: *Writer, col: u32) Writer.Error!void {
    std.debug.assert(col < max_cols);
    var buffer: [3]u8 = undefined;
    var start: usize = buffer.len;
    var n = col + 1;
    while (n > 0) {
        n -= 1;
        start -= 1;
        buffer[start] = 'A' + @as(u8, @intCast(n % 26));
        n /= 26;
    }
    try w.writeAll(buffer[start..]);
}

// internal: used inside the xlsx module; apps do not call it.
// `B7` for row 6, column 1.
pub fn writeCell(w: *Writer, row: u32, col: u32) Writer.Error!void {
    try writeColumnName(w, col);
    try w.print("{d}", .{row + 1});
}

// internal: used inside the xlsx module; apps do not call it.
// `$B$7`, the absolute form defined names use.
pub fn writeAbsoluteCell(w: *Writer, row: u32, col: u32) Writer.Error!void {
    try w.writeByte('$');
    try writeColumnName(w, col);
    try w.print("${d}", .{row + 1});
}

/// A rectangle of cells, both corners included.
pub const Range = struct {
    first_row: u32,
    first_col: u32,
    last_row: u32,
    last_col: u32,

    /// `A1:D51`.
    pub fn write(range: Range, w: *Writer) Writer.Error!void {
        try writeCell(w, range.first_row, range.first_col);
        try w.writeByte(':');
        try writeCell(w, range.last_row, range.last_col);
    }

    /// `$A$1:$D$51`.
    pub fn writeAbsolute(range: Range, w: *Writer) Writer.Error!void {
        try writeAbsoluteCell(w, range.first_row, range.first_col);
        try w.writeByte(':');
        try writeAbsoluteCell(w, range.last_row, range.last_col);
    }
};

const testing = std.testing;

fn expectCell(expected: []const u8, row: u32, col: u32) !void {
    var buffer: [16]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try writeCell(&w, row, col);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "A1 references" {
    try expectCell("A1", 0, 0);
    try expectCell("Z1", 0, 25);
    try expectCell("AA1", 0, 26);
    try expectCell("AZ10", 9, 51);
    try expectCell("BA10", 9, 52);
    try expectCell("ZZ1", 0, 701);
    try expectCell("AAA1", 0, 702);
    try expectCell("XFD1048576", max_rows - 1, max_cols - 1);
}

test "ranges, relative and absolute" {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    const range: Range = .{ .first_row = 0, .first_col = 0, .last_row = 50, .last_col = 3 };
    try range.write(&w);
    try w.writeByte(' ');
    try range.writeAbsolute(&w);
    try testing.expectEqualStrings("A1:D51 $A$1:$D$51", w.buffered());
}
