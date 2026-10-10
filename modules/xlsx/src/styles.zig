//! Cell styles and the `xl/styles.xml` part.
//!
//! In the file format a cell does not carry its formatting: it carries
//! an index (`s="3"`) into a table of format records (`cellXfs`), and
//! each record points into four more tables (fonts, fills, borders,
//! number formats). Callers never see that: they pass a `Style` value
//! with a cell, equal styles share one record, and only the styles some
//! cell ends up using are written.

const std = @import("std");
const Writer = std.Io.Writer;
const xml = @import("xml.zig");

/// The style errors; all of them are part of `xlsx.Error`.
pub const Error = error{
    /// More distinct styles than a workbook can hold.
    TooManyStyles,
    /// A custom number format that is empty, longer than 255 bytes, not UTF-8 or
    /// holds characters XML cannot carry.
    InvalidNumberFormat,
    /// A font name that is empty, longer than 31 bytes, not UTF-8
    /// or holds characters XML cannot carry; or a size outside 1..409.
    InvalidFont,
    /// The default font can only be changed before any style is used.
    StylesAlreadyUsed,
    OutOfMemory,
};

/// A line drawn on the four sides of a cell.
pub const Border = enum {
    none,
    hair,
    dotted,
    dashed,
    thin,
    medium,
    thick,
    double,
};

/// How a cell's background is painted. `solid` covers it with the
/// `fill` colour; the others draw dots of that colour (black without
/// one) over the plain background, from darker to lighter.
pub const FillPattern = enum {
    solid,
    dark_gray,
    medium_gray,
    light_gray,
    gray125,
    gray0625,

    fn xmlName(pattern: FillPattern) []const u8 {
        return switch (pattern) {
            .solid => "solid",
            .dark_gray => "darkGray",
            .medium_gray => "mediumGray",
            .light_gray => "lightGray",
            .gray125 => "gray125",
            .gray0625 => "gray0625",
        };
    }
};

/// How a number is shown. The named ones are formats every spreadsheet
/// program has built in, so they follow the reader's locale (decimal
/// comma, day/month order). `custom` takes a format code in Excel's
/// syntax, written with `.` as the decimal separator, e.g.
/// `"dd/mm/yyyy"` or `"#,##0.00"`.
pub const NumberFormat = union(enum) {
    general,
    /// `0`
    integer,
    /// `0.00`
    decimal,
    /// `#,##0`
    thousands,
    /// `#,##0.00`
    thousands_decimal,
    /// `0%`
    percent,
    /// `0.00%`
    percent_decimal,
    /// The reader's short date.
    date,
    /// `h:mm:ss`
    time,
    /// The reader's short date, then `h:mm`.
    datetime,
    /// Shows the cell as typed, numbers included.
    text,
    custom: []const u8,
};

/// Where a cell's content sits between its left and right edges.
/// `general` is the spreadsheet's own rule: text to the left, numbers
/// to the right.
pub const HorizontalAlignment = enum {
    general,
    left,
    center,
    right,
};

/// Where a cell's content sits between its top and bottom edges.
pub const VerticalAlignment = enum {
    bottom,
    center,
    top,
};

/// The formatting of one cell. The default value is a plain cell.
pub const Style = struct {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    /// Text colour as `0xRRGGBB`.
    font_color: ?u24 = null,
    /// A font family name such as `"Times New Roman"`. The file only
    /// carries the name: the font must exist on the reader's machine.
    /// Null is the workbook's default font (Calibri unless changed).
    font_name: ?[]const u8 = null,
    /// Size in points, 1 to 409, in steps of a tenth. Null is the
    /// workbook's default size (11 unless changed).
    font_size: ?f32 = null,
    /// Background colour as `0xRRGGBB`.
    fill: ?u24 = null,
    fill_pattern: FillPattern = .solid,
    /// The line on the four sides of the cell.
    border: Border = .none,
    /// One side only; when set, it replaces `border` for that side
    /// (`.none` removes the line there).
    border_left: ?Border = null,
    border_right: ?Border = null,
    border_top: ?Border = null,
    border_bottom: ?Border = null,
    /// Colour of the border lines as `0xRRGGBB`; null is the reader's
    /// automatic colour (black).
    border_color: ?u24 = null,
    number_format: NumberFormat = .general,
    h_align: HorizontalAlignment = .general,
    v_align: VerticalAlignment = .bottom,
    /// Breaks long text into lines inside the cell instead of letting
    /// it run over the next cells. Line breaks in the text itself also
    /// only show when this is set.
    wrap: bool = false,
    /// Makes the text smaller, when needed, so it fits the cell's width
    /// on one line. Spreadsheet programs ignore it when `wrap` is set.
    shrink: bool = false,
    /// Lets the cell be edited when its sheet is protected (cells are
    /// locked by default). Has no effect on an unprotected sheet.
    unlocked: bool = false,
};

// internal: used inside the xlsx module; apps do not call it.
// Excel's limit on distinct cell formats.
pub const max_styles = 65_490;
// internal: used inside the xlsx module; apps do not call it.
// Longest custom format code accepted, in bytes.
pub const max_number_format_len = 255;
// internal: used inside the xlsx module; apps do not call it.
// Longest font name accepted, in bytes (Excel's limit is 31 characters).
pub const max_font_name_len = 31;
// internal: used inside the xlsx module; apps do not call it.
// Largest font size accepted, in points.
pub const max_font_size = 409;
const builtin_font_name = "Calibri";
/// Font sizes are kept in tenths of a point.
const builtin_font_size_tenths = 110;
/// First id available for custom number formats; lower ids are built in.
const first_custom_format_id = 164;

/// A style with its number format reduced to an id, so it can be a hash
/// map key.
const Key = struct {
    font: FontKey,
    fill: FillKey,
    border: BorderKey,
    custom_format: bool,
    /// A built-in format id, or an index into `Registry.custom_formats`.
    format: u16,
    h_align: HorizontalAlignment,
    v_align: VerticalAlignment,
    wrap: bool,
    shrink: bool,
    unlocked: bool,

    const default: Key = .{
        .font = .default,
        .fill = .none,
        .border = .none,
        .custom_format = false,
        .format = 0,
        .h_align = .general,
        .v_align = .bottom,
        .wrap = false,
        .shrink = false,
        .unlocked = false,
    };

    fn hasAlignment(key: Key) bool {
        return key.h_align != .general or key.v_align != .bottom or key.wrap or key.shrink;
    }
};

/// One entry of the fills table.
const FillKey = struct {
    /// False with the solid pattern means "no fill".
    has_color: bool,
    color: u24,
    pattern: FillPattern,

    const none: FillKey = .{ .has_color = false, .color = 0, .pattern = .solid };
};

/// One entry of the borders table.
const BorderKey = struct {
    /// Left, right, top, bottom.
    sides: [4]Border,
    has_color: bool,
    color: u24,

    const none: BorderKey = .{ .sides = @splat(.none), .has_color = false, .color = 0 };
};

/// One entry of the fonts table.
const FontKey = struct {
    bold: bool,
    italic: bool,
    underline: bool,
    has_color: bool,
    color: u24,
    /// 0 is the workbook's default font; otherwise 1 + an index into
    /// `Registry.font_names`.
    name: u16,
    /// 0 is the workbook's default size.
    size_tenths: u16,

    const default: FontKey = .{
        .bold = false,
        .italic = false,
        .underline = false,
        .has_color = false,
        .color = 0,
        .name = 0,
        .size_tenths = 0,
    };
};

// internal: the workbook's table of styles.
// Every distinct style a workbook was given. Id 0 is the default
// style; the others are handed out in the order styles are first seen.
pub const Registry = struct {
    keys: std.ArrayList(Key) = .empty,
    ids: std.AutoHashMapUnmanaged(Key, u16) = .empty,
    custom_formats: std.ArrayList([]const u8) = .empty,
    custom_ids: std.StringHashMapUnmanaged(u16) = .empty,
    /// Font names other than the default, as first given.
    font_names: std.ArrayList([]const u8) = .empty,
    /// The font of cells whose style names none. Column widths are
    /// measured in characters of this font.
    default_font_name: []const u8 = builtin_font_name,
    default_font_size_tenths: u16 = builtin_font_size_tenths,

    /// Changes the default font. Only before any style is registered:
    /// styles are stored relative to the default.
    pub fn setDefaultFont(self: *Registry, arena: std.mem.Allocator, name: []const u8, size: f32) Error!void {
        if (self.keys.items.len > 1 or self.font_names.items.len > 0) return error.StylesAlreadyUsed;
        try checkFontName(name);
        const size_tenths = try fontSizeTenths(size);
        self.default_font_name = try arena.dupe(u8, name);
        self.default_font_size_tenths = size_tenths;
    }

    // internal: used inside the xlsx module; apps do not call it.
    // The default font's size in points.
    pub fn defaultFontSize(self: *const Registry) f64 {
        return @as(f64, @floatFromInt(self.default_font_size_tenths)) / 10.0;
    }

    // internal: true while the default font is still Calibri 11.
    pub fn hasBuiltinDefaultFont(self: *const Registry) bool {
        return self.default_font_size_tenths == builtin_font_size_tenths and
            std.ascii.eqlIgnoreCase(self.default_font_name, builtin_font_name);
    }

    // internal: used inside the xlsx module; apps do not call it.
    // Returns the id of `style`, registering it if it is new. Memory
    // comes from `arena` and is never freed individually.
    pub fn intern(self: *Registry, arena: std.mem.Allocator, style: Style) Error!u16 {
        if (self.keys.items.len == 0) try self.keys.append(arena, .default);

        var key: Key = .{
            .font = .{
                .bold = style.bold,
                .italic = style.italic,
                .underline = style.underline,
                .has_color = style.font_color != null,
                .color = style.font_color orelse 0,
                .name = if (style.font_name) |name| try self.internFontName(arena, name) else 0,
                .size_tenths = if (style.font_size) |size| try self.internFontSize(size) else 0,
            },
            .fill = .{ .has_color = style.fill != null, .color = style.fill orelse 0, .pattern = style.fill_pattern },
            .border = .{
                .sides = .{
                    style.border_left orelse style.border,
                    style.border_right orelse style.border,
                    style.border_top orelse style.border,
                    style.border_bottom orelse style.border,
                },
                .has_color = style.border_color != null,
                .color = style.border_color orelse 0,
            },
            .custom_format = false,
            .format = 0,
            .h_align = style.h_align,
            .v_align = style.v_align,
            .wrap = style.wrap,
            .shrink = style.shrink,
            .unlocked = style.unlocked,
        };
        // A colour without a line draws nothing: not a style of its own.
        if (std.meta.eql(key.border.sides, BorderKey.none.sides)) key.border = .none;
        switch (style.number_format) {
            .custom => |code| {
                key.custom_format = true;
                key.format = try self.internFormat(arena, code);
            },
            else => |named| key.format = builtinId(named),
        }
        if (std.meta.eql(key, Key.default)) return 0;

        const entry = try self.ids.getOrPut(arena, key);
        if (entry.found_existing) return entry.value_ptr.*;
        if (self.keys.items.len >= max_styles) {
            _ = self.ids.remove(key);
            return error.TooManyStyles;
        }
        const id: u16 = @intCast(self.keys.items.len);
        entry.value_ptr.* = id;
        try self.keys.append(arena, key);
        return id;
    }

    fn internFormat(self: *Registry, arena: std.mem.Allocator, code: []const u8) Error!u16 {
        if (code.len == 0 or code.len > max_number_format_len) return error.InvalidNumberFormat;
        if (!std.unicode.utf8ValidateSlice(code) or !xml.isXmlSafe(code)) return error.InvalidNumberFormat;
        if (self.custom_ids.get(code)) |id| return id;
        const owned = try arena.dupe(u8, code);
        const id: u16 = @intCast(self.custom_formats.items.len);
        try self.custom_formats.append(arena, owned);
        try self.custom_ids.put(arena, owned, id);
        return id;
    }

    /// Font names compare without ASCII case, as font lookup does.
    fn internFontSize(self: *const Registry, size: f32) Error!u16 {
        const tenths = try fontSizeTenths(size);
        return if (tenths == self.default_font_size_tenths) 0 else tenths;
    }

    fn internFontName(self: *Registry, arena: std.mem.Allocator, name: []const u8) Error!u16 {
        try checkFontName(name);
        if (std.ascii.eqlIgnoreCase(name, self.default_font_name)) return 0;
        for (self.font_names.items, 1..) |known, id| {
            if (std.ascii.eqlIgnoreCase(known, name)) return @intCast(id);
        }
        try self.font_names.append(arena, try arena.dupe(u8, name));
        return @intCast(self.font_names.items.len);
    }

    /// Number of ids handed out, the default style included.
    pub fn count(self: *const Registry) usize {
        return @max(self.keys.items.len, 1);
    }

    /// Writes `xl/styles.xml` for the styles in `used`: registry ids in
    /// the order their format records must appear. The default style is
    /// always record 0 and must not be listed; `used[i]` becomes record
    /// `i + 1`, which is the value cells put in their `s` attribute.
    pub fn write(self: *const Registry, w: *Writer, scratch: std.mem.Allocator, used: []const u16) (Writer.Error || error{OutOfMemory})!void {
        var fills: std.ArrayList(FillKey) = .empty;
        defer fills.deinit(scratch);
        var borders: std.ArrayList(BorderKey) = .empty;
        defer borders.deinit(scratch);
        var formats: std.ArrayList(u16) = .empty;
        defer formats.deinit(scratch);
        var fonts: std.ArrayList(FontKey) = .empty;
        defer fonts.deinit(scratch);
        try fonts.append(scratch, .default);

        const Record = struct { font: u32, fill: u32, border: u32, format: u32, key: Key };
        var records: std.ArrayList(Record) = .empty;
        defer records.deinit(scratch);

        for (used) |id| {
            const key = self.keys.items[id];
            var record: Record = .{ .font = 0, .fill = 0, .border = 0, .format = key.format, .key = key };
            record.font = @intCast(try indexOrAppend(FontKey, scratch, &fonts, key.font));
            if (!std.meta.eql(key.fill, FillKey.none)) {
                // Fills 0 and 1 are fixed by the format (see below).
                record.fill = 2 + @as(u32, @intCast(try indexOrAppend(FillKey, scratch, &fills, key.fill)));
            }
            if (!std.meta.eql(key.border, BorderKey.none)) {
                record.border = 1 + @as(u32, @intCast(try indexOrAppend(BorderKey, scratch, &borders, key.border)));
            }
            if (key.custom_format) {
                record.format = first_custom_format_id + @as(u32, @intCast(try indexOrAppend(u16, scratch, &formats, key.format)));
            }
            try records.append(scratch, record);
        }

        try w.writeAll(xml.declaration);
        try w.writeAll("<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">");

        if (formats.items.len > 0) {
            try w.print("<numFmts count=\"{d}\">", .{formats.items.len});
            for (formats.items, 0..) |format, i| {
                try w.print("<numFmt numFmtId=\"{d}\" formatCode=\"", .{first_custom_format_id + i});
                try xml.writeAttribute(w, self.custom_formats.items[format]);
                try w.writeAll("\"/>");
            }
            try w.writeAll("</numFmts>");
        }

        // Child order is fixed by the format: b, i, u, sz, color, name, family.
        try w.print("<fonts count=\"{d}\">", .{fonts.items.len});
        for (fonts.items) |font| {
            try w.writeAll("<font>");
            if (font.bold) try w.writeAll("<b/>");
            if (font.italic) try w.writeAll("<i/>");
            if (font.underline) try w.writeAll("<u/>");
            const size_tenths = if (font.size_tenths == 0) self.default_font_size_tenths else font.size_tenths;
            try w.print("<sz val=\"{d}", .{size_tenths / 10});
            if (size_tenths % 10 != 0) try w.print(".{d}", .{size_tenths % 10});
            try w.writeAll("\"/>");
            if (font.has_color) try w.print("<color rgb=\"FF{X:0>6}\"/>", .{font.color});
            const name = if (font.name == 0) self.default_font_name else self.font_names.items[font.name - 1];
            try w.writeAll("<name val=\"");
            try xml.writeAttribute(w, name);
            try w.writeAll("\"/>");
            // Family 2 is "swiss" (sans-serif), right for Calibri only.
            if (font.name == 0 and std.ascii.eqlIgnoreCase(name, builtin_font_name)) try w.writeAll("<family val=\"2\"/>");
            try w.writeAll("</font>");
        }
        try w.writeAll("</fonts>");

        // The first two fills are mandatory: readers assume fill 0 is
        // "none" and fill 1 is the 12.5% grey pattern.
        try w.print("<fills count=\"{d}\">", .{fills.items.len + 2});
        try w.writeAll("<fill><patternFill patternType=\"none\"/></fill>");
        try w.writeAll("<fill><patternFill patternType=\"gray125\"/></fill>");
        for (fills.items) |fill| {
            try w.print("<fill><patternFill patternType=\"{s}\"", .{fill.pattern.xmlName()});
            if (fill.has_color) {
                try w.print("><fgColor rgb=\"FF{X:0>6}\"/><bgColor indexed=\"64\"/></patternFill></fill>", .{fill.color});
            } else try w.writeAll("/></fill>");
        }
        try w.writeAll("</fills>");

        try w.print("<borders count=\"{d}\">", .{borders.items.len + 1});
        try w.writeAll("<border><left/><right/><top/><bottom/><diagonal/></border>");
        for (borders.items) |border| {
            try w.writeAll("<border>");
            for ([_][]const u8{ "left", "right", "top", "bottom" }, border.sides) |side, line| {
                if (line == .none) {
                    try w.print("<{s}/>", .{side});
                } else if (border.has_color) {
                    try w.print("<{s} style=\"{t}\"><color rgb=\"FF{X:0>6}\"/></{s}>", .{ side, line, border.color, side });
                } else {
                    try w.print("<{s} style=\"{t}\"><color auto=\"1\"/></{s}>", .{ side, line, side });
                }
            }
            try w.writeAll("<diagonal/></border>");
        }
        try w.writeAll("</borders>");

        try w.writeAll("<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>");

        try w.print("<cellXfs count=\"{d}\">", .{records.items.len + 1});
        try w.writeAll("<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>");
        for (records.items) |record| {
            try w.print("<xf numFmtId=\"{d}\" fontId=\"{d}\" fillId=\"{d}\" borderId=\"{d}\" xfId=\"0\"", .{ record.format, record.font, record.fill, record.border });
            if (record.format != 0) try w.writeAll(" applyNumberFormat=\"1\"");
            if (record.font != 0) try w.writeAll(" applyFont=\"1\"");
            if (record.fill != 0) try w.writeAll(" applyFill=\"1\"");
            if (record.border != 0) try w.writeAll(" applyBorder=\"1\"");
            if (record.key.hasAlignment()) try w.writeAll(" applyAlignment=\"1\"");
            if (record.key.unlocked) try w.writeAll(" applyProtection=\"1\"");
            if (record.key.hasAlignment() or record.key.unlocked) {
                try w.writeByte('>');
                if (record.key.hasAlignment()) {
                    try w.writeAll("<alignment");
                    if (record.key.h_align != .general) try w.print(" horizontal=\"{t}\"", .{record.key.h_align});
                    if (record.key.v_align != .bottom) try w.print(" vertical=\"{t}\"", .{record.key.v_align});
                    if (record.key.wrap) try w.writeAll(" wrapText=\"1\"");
                    if (record.key.shrink) try w.writeAll(" shrinkToFit=\"1\"");
                    try w.writeAll("/>");
                }
                if (record.key.unlocked) try w.writeAll("<protection locked=\"0\"/>");
                try w.writeAll("</xf>");
            } else try w.writeAll("/>");
        }
        try w.writeAll("</cellXfs>");

        try w.writeAll("<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>");
        try w.writeAll("</styleSheet>");
    }
};

fn checkFontName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > max_font_name_len) return error.InvalidFont;
    if (!std.unicode.utf8ValidateSlice(name) or !xml.isXmlSafe(name)) return error.InvalidFont;
}

fn fontSizeTenths(size: f32) Error!u16 {
    if (!std.math.isFinite(size) or size < 1 or size > max_font_size) return error.InvalidFont;
    return @intFromFloat(@round(size * 10));
}

/// Ids of the number formats every reader has built in.
fn builtinId(format: NumberFormat) u16 {
    return switch (format) {
        .general => 0,
        .integer => 1,
        .decimal => 2,
        .thousands => 3,
        .thousands_decimal => 4,
        .percent => 9,
        .percent_decimal => 10,
        .date => 14,
        .time => 21,
        .datetime => 22,
        .text => 49,
        .custom => unreachable,
    };
}

fn indexOrAppend(comptime T: type, allocator: std.mem.Allocator, list: *std.ArrayList(T), value: T) error{OutOfMemory}!usize {
    for (list.items, 0..) |item, i| {
        if (std.meta.eql(item, value)) return i;
    }
    try list.append(allocator, value);
    return list.items.len - 1;
}

const testing = std.testing;

fn expectStylesXml(registry: *const Registry, used: []const u16, expected_body: []const u8) !void {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try registry.write(&out.writer, testing.allocator, used);
    const prefix = xml.declaration ++ "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">";
    const suffix = "</styleSheet>";
    const written = out.written();
    try testing.expect(std.mem.startsWith(u8, written, prefix));
    try testing.expect(std.mem.endsWith(u8, written, suffix));
    try testing.expectEqualStrings(expected_body, written[prefix.len .. written.len - suffix.len]);
}

const minimal_body =
    "<fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/><family val=\"2\"/></font></fonts>" ++
    "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>" ++
    "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>" ++
    "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>" ++
    "<cellXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/></cellXfs>" ++
    "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>";

test "the default style is id 0 and equal styles share an id" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry: Registry = .{};

    try testing.expectEqual(@as(u16, 0), try registry.intern(arena, .{}));
    try testing.expectEqual(@as(u16, 0), try registry.intern(arena, .{ .number_format = .general, .border = .none }));
    const bold = try registry.intern(arena, .{ .bold = true });
    const money = try registry.intern(arena, .{ .number_format = .{ .custom = "#,##0.00" } });
    try testing.expectEqual(@as(u16, 1), bold);
    try testing.expectEqual(@as(u16, 2), money);
    try testing.expectEqual(bold, try registry.intern(arena, .{ .bold = true }));
    // Same code from another buffer: still the same style.
    var code: [8]u8 = "#,##0.00".*;
    try testing.expectEqual(money, try registry.intern(arena, .{ .number_format = .{ .custom = &code } }));
    // Black fill is not "no fill".
    try testing.expectEqual(@as(u16, 3), try registry.intern(arena, .{ .fill = 0x000000 }));
    try testing.expectEqual(@as(usize, 4), registry.count());
}

test "styles.xml with no styles is the fixed minimum" {
    const registry: Registry = .{};
    try testing.expectEqual(@as(usize, 1), registry.count());
    try expectStylesXml(&registry, &.{}, minimal_body);
}

test "styles.xml: fonts, fills, borders and number formats are shared between records" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry: Registry = .{};

    const header = try registry.intern(arena, .{ .bold = true, .fill = 0xDDEEFF, .border = .thin });
    const percent = try registry.intern(arena, .{ .number_format = .percent_decimal });
    const br_date = try registry.intern(arena, .{ .number_format = .{ .custom = "dd/mm/yyyy" } });
    const total = try registry.intern(arena, .{ .bold = true, .fill = 0xDDEEFF, .border = .medium, .number_format = .{ .custom = "dd/mm/yyyy" } });
    const unused = try registry.intern(arena, .{ .fill = 0xFF0000, .number_format = .{ .custom = "0.000" } });
    _ = unused;

    try expectStylesXml(&registry, &.{ header, percent, br_date, total }, "<numFmts count=\"1\"><numFmt numFmtId=\"164\" formatCode=\"dd/mm/yyyy\"/></numFmts>" ++
        "<fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/><family val=\"2\"/></font>" ++
        "<font><b/><sz val=\"11\"/><name val=\"Calibri\"/><family val=\"2\"/></font></fonts>" ++
        "<fills count=\"3\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill>" ++
        "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FFDDEEFF\"/><bgColor indexed=\"64\"/></patternFill></fill></fills>" ++
        "<borders count=\"3\"><border><left/><right/><top/><bottom/><diagonal/></border>" ++
        "<border><left style=\"thin\"><color auto=\"1\"/></left><right style=\"thin\"><color auto=\"1\"/></right>" ++
        "<top style=\"thin\"><color auto=\"1\"/></top><bottom style=\"thin\"><color auto=\"1\"/></bottom><diagonal/></border>" ++
        "<border><left style=\"medium\"><color auto=\"1\"/></left><right style=\"medium\"><color auto=\"1\"/></right>" ++
        "<top style=\"medium\"><color auto=\"1\"/></top><bottom style=\"medium\"><color auto=\"1\"/></bottom><diagonal/></border></borders>" ++
        "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>" ++
        "<cellXfs count=\"5\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>" ++
        "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"2\" borderId=\"1\" xfId=\"0\" applyFont=\"1\" applyFill=\"1\" applyBorder=\"1\"/>" ++
        "<xf numFmtId=\"10\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>" ++
        "<xf numFmtId=\"164\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>" ++
        "<xf numFmtId=\"164\" fontId=\"1\" fillId=\"2\" borderId=\"2\" xfId=\"0\" applyNumberFormat=\"1\" applyFont=\"1\" applyFill=\"1\" applyBorder=\"1\"/>" ++
        "</cellXfs>" ++
        "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>");
}

test "a custom format code is escaped as an attribute" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var registry: Registry = .{};
    const id = try registry.intern(arena_state.allocator(), .{ .number_format = .{ .custom = "0.0\" m<s>\" & 0" } });

    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try registry.write(&out.writer, testing.allocator, &.{id});
    try testing.expect(std.mem.indexOf(u8, out.written(), "formatCode=\"0.0&quot; m&lt;s&gt;&quot; &amp; 0\"") != null);
}

test "bad custom formats are refused" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry: Registry = .{};

    const too_long: [max_number_format_len + 1]u8 = @splat('0');
    for ([_][]const u8{ "", &too_long, "0\x01", "\xff\xfe" }) |code| {
        try testing.expectError(error.InvalidNumberFormat, registry.intern(arena, .{ .number_format = .{ .custom = code } }));
    }
    try testing.expectEqual(@as(usize, 1), registry.count());
}

test "the style limit is enforced" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry: Registry = .{};

    var colour: u24 = 0;
    while (registry.count() < max_styles) : (colour += 1) {
        _ = try registry.intern(arena, .{ .fill = colour });
    }
    try testing.expectError(error.TooManyStyles, registry.intern(arena, .{ .fill = colour }));
    // A style already known is still served, and the failed one left no trace.
    try testing.expectEqual(@as(u16, 1), try registry.intern(arena, .{ .fill = 0 }));
    try testing.expectError(error.TooManyStyles, registry.intern(arena, .{ .fill = colour }));
}

test "alignment and wrap are part of the style and of its record" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry: Registry = .{};

    // The defaults spelled out are still the default style.
    try testing.expectEqual(@as(u16, 0), try registry.intern(arena, .{ .h_align = .general, .v_align = .bottom, .wrap = false }));
    const centered = try registry.intern(arena, .{ .h_align = .center, .v_align = .center, .wrap = true });
    const left = try registry.intern(arena, .{ .h_align = .left });
    const right_top = try registry.intern(arena, .{ .h_align = .right, .v_align = .top });
    const wrapped = try registry.intern(arena, .{ .wrap = true });
    const bold_centered = try registry.intern(arena, .{ .bold = true, .h_align = .center });
    try testing.expectEqual(centered, try registry.intern(arena, .{ .wrap = true, .v_align = .center, .h_align = .center }));
    try testing.expect(left != right_top and wrapped != centered and bold_centered != centered);

    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try registry.write(&out.writer, testing.allocator, &.{ centered, left, right_top, wrapped, bold_centered });
    try testing.expect(std.mem.indexOf(u8, out.written(), "<cellXfs count=\"6\">" ++
        "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>" ++
        "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyAlignment=\"1\">" ++
        "<alignment horizontal=\"center\" vertical=\"center\" wrapText=\"1\"/></xf>" ++
        "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyAlignment=\"1\">" ++
        "<alignment horizontal=\"left\"/></xf>" ++
        "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyAlignment=\"1\">" ++
        "<alignment horizontal=\"right\" vertical=\"top\"/></xf>" ++
        "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyAlignment=\"1\">" ++
        "<alignment wrapText=\"1\"/></xf>" ++
        "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyAlignment=\"1\">" ++
        "<alignment horizontal=\"center\"/></xf>" ++
        "</cellXfs>") != null);
}

test "fonts: name, size, colour, italic and underline, shared between records" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry: Registry = .{};

    // Calibri 11 spelled out is the default font, with or without case.
    try testing.expectEqual(@as(u16, 0), try registry.intern(arena, .{ .font_name = "Calibri", .font_size = 11 }));
    try testing.expectEqual(@as(u16, 0), try registry.intern(arena, .{ .font_name = "calibri" }));

    const times = try registry.intern(arena, .{ .font_name = "Times New Roman", .font_size = 10 });
    const fancy = try registry.intern(arena, .{ .bold = true, .italic = true, .underline = true, .font_color = 0x1F497D, .font_size = 10.5 });
    const times_filled = try registry.intern(arena, .{ .font_name = "Times New Roman", .font_size = 10, .fill = 0xFFFFFF });
    var name: [15]u8 = "times new roman".*;
    try testing.expectEqual(times, try registry.intern(arena, .{ .font_name = &name, .font_size = 10 }));
    // Black text is not "no colour".
    try testing.expect(try registry.intern(arena, .{ .font_color = 0x000000 }) != 0);

    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try registry.write(&out.writer, testing.allocator, &.{ times, fancy, times_filled });
    const written = out.written();
    try testing.expect(std.mem.indexOf(u8, written, "<fonts count=\"3\">" ++
        "<font><sz val=\"11\"/><name val=\"Calibri\"/><family val=\"2\"/></font>" ++
        "<font><sz val=\"10\"/><name val=\"Times New Roman\"/></font>" ++
        "<font><b/><i/><u/><sz val=\"10.5\"/><color rgb=\"FF1F497D\"/><name val=\"Calibri\"/><family val=\"2\"/></font>" ++
        "</fonts>") != null);
    try testing.expect(std.mem.indexOf(u8, written, "<cellXfs count=\"4\">" ++
        "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>" ++
        "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/>" ++
        "<xf numFmtId=\"0\" fontId=\"2\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/>" ++
        "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"2\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyFill=\"1\"/>" ++
        "</cellXfs>") != null);
}

test "a font name is escaped, and bad fonts are refused" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry: Registry = .{};

    const id = try registry.intern(arena, .{ .font_name = "A&B \"Sans\"" });
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try registry.write(&out.writer, testing.allocator, &.{id});
    try testing.expect(std.mem.indexOf(u8, out.written(), "<name val=\"A&amp;B &quot;Sans&quot;\"/>") != null);

    const count = registry.count();
    const too_long: [max_font_name_len + 1]u8 = @splat('a');
    for ([_][]const u8{ "", &too_long, "Bad\x01", "\xff" }) |bad| {
        try testing.expectError(error.InvalidFont, registry.intern(arena, .{ .font_name = bad }));
    }
    for ([_]f32{ 0, 0.5, 409.5, -1, std.math.nan(f32), std.math.inf(f32) }) |bad| {
        try testing.expectError(error.InvalidFont, registry.intern(arena, .{ .font_size = bad }));
    }
    _ = try registry.intern(arena, .{ .font_size = 1 });
    _ = try registry.intern(arena, .{ .font_size = 409 });
    try testing.expectEqual(count + 2, registry.count());
}

test "shrink to fit is an alignment flag" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry: Registry = .{};

    try testing.expectEqual(@as(u16, 0), try registry.intern(arena, .{ .shrink = false }));
    const shrunk = try registry.intern(arena, .{ .shrink = true });
    const shrunk_centered = try registry.intern(arena, .{ .shrink = true, .h_align = .center, .v_align = .center });
    try testing.expect(shrunk != 0 and shrunk != shrunk_centered);

    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try registry.write(&out.writer, testing.allocator, &.{ shrunk, shrunk_centered });
    try testing.expect(std.mem.indexOf(u8, out.written(), "applyAlignment=\"1\"><alignment shrinkToFit=\"1\"/></xf>" ++
        "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyAlignment=\"1\">" ++
        "<alignment horizontal=\"center\" vertical=\"center\" shrinkToFit=\"1\"/></xf>") != null);
}

test "borders can differ per side" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry: Registry = .{};

    // Sides spelled out equal to `border` are the same style.
    const all_thin = try registry.intern(arena, .{ .border = .thin });
    try testing.expectEqual(all_thin, try registry.intern(arena, .{ .border_left = .thin, .border_right = .thin, .border_top = .thin, .border_bottom = .thin }));
    try testing.expectEqual(@as(u16, 0), try registry.intern(arena, .{ .border_top = .none }));

    const underline_only = try registry.intern(arena, .{ .border_bottom = .thin });
    const open_top = try registry.intern(arena, .{ .border = .thin, .border_top = .none });
    const mixed = try registry.intern(arena, .{ .border = .thin, .border_bottom = .thick, .border_left = .medium });

    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try registry.write(&out.writer, testing.allocator, &.{ underline_only, open_top, mixed });
    try testing.expect(std.mem.indexOf(u8, out.written(), "<borders count=\"4\">" ++
        "<border><left/><right/><top/><bottom/><diagonal/></border>" ++
        "<border><left/><right/><top/><bottom style=\"thin\"><color auto=\"1\"/></bottom><diagonal/></border>" ++
        "<border><left style=\"thin\"><color auto=\"1\"/></left><right style=\"thin\"><color auto=\"1\"/></right>" ++
        "<top/><bottom style=\"thin\"><color auto=\"1\"/></bottom><diagonal/></border>" ++
        "<border><left style=\"medium\"><color auto=\"1\"/></left><right style=\"thin\"><color auto=\"1\"/></right>" ++
        "<top style=\"thin\"><color auto=\"1\"/></top><bottom style=\"thick\"><color auto=\"1\"/></bottom><diagonal/></border>" ++
        "</borders>") != null);
}

test "fill patterns, more border lines and border colour" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry: Registry = .{};

    // Solid is the default pattern, and a pattern needs no colour.
    try testing.expectEqual(try registry.intern(arena, .{ .fill = 0xFFFF00 }), try registry.intern(arena, .{ .fill = 0xFFFF00, .fill_pattern = .solid }));
    try testing.expectEqual(@as(u16, 0), try registry.intern(arena, .{ .fill_pattern = .solid }));
    try testing.expectEqual(@as(u16, 0), try registry.intern(arena, .{ .border_color = 0xFF0000 }));
    const dotted_red = try registry.intern(arena, .{ .fill = 0xFF0000, .fill_pattern = .light_gray });
    const plain_gray = try registry.intern(arena, .{ .fill_pattern = .gray125 });
    const double_line = try registry.intern(arena, .{ .border_bottom = .double });
    const dotted_blue = try registry.intern(arena, .{ .border = .dotted, .border_color = 0x0000FF });
    const hair_dashed = try registry.intern(arena, .{ .border_left = .hair, .border_right = .dashed });
    const thin_black = try registry.intern(arena, .{ .border = .thin });
    try testing.expect(dotted_blue != try registry.intern(arena, .{ .border = .dotted }));

    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try registry.write(&out.writer, testing.allocator, &.{ dotted_red, plain_gray, double_line, dotted_blue, hair_dashed, thin_black });
    const written = out.written();
    try testing.expect(std.mem.indexOf(u8, written, "<fills count=\"4\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill>" ++
        "<fill><patternFill patternType=\"lightGray\"><fgColor rgb=\"FFFF0000\"/><bgColor indexed=\"64\"/></patternFill></fill>" ++
        "<fill><patternFill patternType=\"gray125\"/></fill></fills>") != null);
    try testing.expect(std.mem.indexOf(u8, written, "<borders count=\"5\"><border><left/><right/><top/><bottom/><diagonal/></border>" ++
        "<border><left/><right/><top/><bottom style=\"double\"><color auto=\"1\"/></bottom><diagonal/></border>" ++
        "<border><left style=\"dotted\"><color rgb=\"FF0000FF\"/></left><right style=\"dotted\"><color rgb=\"FF0000FF\"/></right>" ++
        "<top style=\"dotted\"><color rgb=\"FF0000FF\"/></top><bottom style=\"dotted\"><color rgb=\"FF0000FF\"/></bottom><diagonal/></border>" ++
        "<border><left style=\"hair\"><color auto=\"1\"/></left><right style=\"dashed\"><color auto=\"1\"/></right><top/><bottom/><diagonal/></border>" ++
        "<border><left style=\"thin\"><color auto=\"1\"/></left>") != null);
}
