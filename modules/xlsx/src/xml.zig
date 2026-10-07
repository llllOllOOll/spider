//! XML output helpers. There is no XML tree: every part is written
//! straight to a `std.Io.Writer`, and these functions escape the three
//! kinds of text a workbook contains.
//!
//! All inputs are expected to be valid UTF-8 (the workbook checks that
//! before storing anything).

const std = @import("std");
const Writer = std.Io.Writer;

pub const declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n";

/// Element content that is not cell text: formulas, defined names.
/// Escapes `&`, `<` and `>`.
pub fn writeText(w: *Writer, text: []const u8) Writer.Error!void {
    for (text) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
}

/// An attribute value (written between double quotes by the caller).
/// Tab, line feed and carriage return become character references,
/// otherwise an XML parser would turn them into spaces.
pub fn writeAttribute(w: *Writer, value: []const u8) Writer.Error!void {
    for (value) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\t' => try w.writeAll("&#x9;"),
        '\n' => try w.writeAll("&#xA;"),
        '\r' => try w.writeAll("&#xD;"),
        else => try w.writeByte(c),
    };
}

/// Cell text, as SpreadsheetML's ST_Xstring.
///
/// XML 1.0 cannot carry most control characters, so the format spells
/// them `_xHHHH_` (four hex digits of the UTF-16 code unit). Rules
/// applied here:
/// - `&`, `<`, `>` are XML-escaped;
/// - tab and line feed are written as they are (a line break inside a
///   cell is a literal line feed);
/// - carriage return and every other C0 control character become
///   `_xHHHH_`, and so do U+FFFE and U+FFFF, which XML forbids;
/// - an underscore that starts something that already looks like
///   `_xHHHH_` in the user's text is written `_x005F_`, so the text
///   reads back unchanged. Only that exact shape is escaped: escaping
///   more makes Excel report the file as damaged.
pub fn writeCellText(w: *Writer, text: []const u8) Writer.Error!void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '\t', '\n' => try w.writeByte(c),
            0x00...0x08, 0x0b...0x1f => try w.print("_x{X:0>4}_", .{@as(u16, c)}),
            '_' => if (looksLikeEscape(text[i..]))
                try w.writeAll("_x005F_")
            else
                try w.writeByte('_'),
            0xef => if (i + 2 < text.len and text[i + 1] == 0xbf and (text[i + 2] == 0xbe or text[i + 2] == 0xbf)) {
                try w.print("_xFFF{c}_", .{@as(u8, if (text[i + 2] == 0xbe) 'E' else 'F')});
                i += 2;
            } else try w.writeByte(c),
            else => try w.writeByte(c),
        }
    }
}

/// True for text starting with `_xHHHH_`.
fn looksLikeEscape(text: []const u8) bool {
    if (text.len < 7) return false;
    if (text[0] != '_' or text[1] != 'x' or text[6] != '_') return false;
    for (text[2..6]) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// Whether cell text needs `xml:space="preserve"` on its `<t>`: XML
/// tools may otherwise drop leading and trailing whitespace.
pub fn needsSpacePreserve(text: []const u8) bool {
    if (text.len == 0) return false;
    return isXmlSpace(text[0]) or isXmlSpace(text[text.len - 1]);
}

fn isXmlSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// True when `text` only holds characters XML 1.0 allows. Used for text
/// that has no `_xHHHH_` convention (sheet names, formulas, number
/// formats): those are refused instead of escaped.
pub fn isXmlSafe(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c < 0x20 and c != '\t' and c != '\n' and c != '\r') return false;
        if (c == 0xef and i + 2 < text.len and text[i + 1] == 0xbf and (text[i + 2] == 0xbe or text[i + 2] == 0xbf)) return false;
    }
    return true;
}

const testing = std.testing;

fn expectWritten(comptime f: fn (*Writer, []const u8) Writer.Error!void, expected: []const u8, input: []const u8) !void {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try f(&out.writer, input);
    try testing.expectEqualStrings(expected, out.written());
}

test "element text escapes the three markup characters" {
    try expectWritten(writeText, "IF(A1&lt;B1,\"x\"&amp;C1,A1&gt;0)", "IF(A1<B1,\"x\"&C1,A1>0)");
    try expectWritten(writeText, "a\"b'c", "a\"b'c");
}

test "attribute values escape quotes and whitespace controls" {
    try expectWritten(writeAttribute, "Tom &amp; &quot;Jerry&quot; &lt;3&gt;", "Tom & \"Jerry\" <3>");
    try expectWritten(writeAttribute, "a&#x9;b&#xA;c&#xD;d", "a\tb\nc\rd");
    try expectWritten(writeAttribute, "it's", "it's");
}

test "cell text: markup, line breaks and accents" {
    try expectWritten(writeCellText, "a &lt; b &amp;&amp; c &gt; d", "a < b && c > d");
    try expectWritten(writeCellText, "linha 1\nlinha 2\tfim", "linha 1\nlinha 2\tfim");
    try expectWritten(writeCellText, "Opção — ação ✓ 😀", "Opção — ação ✓ 😀");
    try expectWritten(writeCellText, "\"quoted\" 'text'", "\"quoted\" 'text'");
}

test "cell text: control characters become _xHHHH_" {
    try expectWritten(writeCellText, "a_x0000_b", "a\x00b");
    try expectWritten(writeCellText, "a_x0001_b_x0008_c", "a\x01b\x08c");
    try expectWritten(writeCellText, "a_x000B_b_x000C_c", "a\x0bb\x0cc");
    try expectWritten(writeCellText, "a_x000D_\nb", "a\r\nb");
    try expectWritten(writeCellText, "a_x001F_b", "a\x1fb");
    try expectWritten(writeCellText, "a_xFFFE_b_xFFFF_c", "a\u{FFFE}b\u{FFFF}c");
    // U+FFFD and other characters sharing the 0xEF lead byte are untouched.
    try expectWritten(writeCellText, "a\u{FFFD}b\u{F000}c", "a\u{FFFD}b\u{F000}c");
}

test "cell text: only a literal _xHHHH_ gets its underscore escaped" {
    try expectWritten(writeCellText, "_x005F_x000D_", "_x000D_");
    try expectWritten(writeCellText, "a_x005F_xABcd_b", "a_xABcd_b");
    // Not the escape shape: left alone.
    try expectWritten(writeCellText, "foo_x12345.txt", "foo_x12345.txt");
    try expectWritten(writeCellText, "_x12_", "_x12_");
    try expectWritten(writeCellText, "_xZZZZ_", "_xZZZZ_");
    try expectWritten(writeCellText, "snake_case_name", "snake_case_name");
    try expectWritten(writeCellText, "_X000D_", "_X000D_");
    try expectWritten(writeCellText, "_", "_");
}

test "space preservation is asked for leading and trailing whitespace only" {
    try testing.expect(needsSpacePreserve(" a"));
    try testing.expect(needsSpacePreserve("a "));
    try testing.expect(needsSpacePreserve("a\n"));
    try testing.expect(needsSpacePreserve("\ta"));
    try testing.expect(!needsSpacePreserve("a b"));
    try testing.expect(!needsSpacePreserve(""));
}

test "isXmlSafe refuses what XML cannot carry" {
    try testing.expect(isXmlSafe("Plan 1\tok\n"));
    try testing.expect(isXmlSafe("ação"));
    try testing.expect(!isXmlSafe("a\x00b"));
    try testing.expect(!isXmlSafe("a\x1bb"));
    try testing.expect(!isXmlSafe("a\u{FFFF}b"));
}
