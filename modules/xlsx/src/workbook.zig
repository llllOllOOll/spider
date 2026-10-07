//! The workbook: sheets, cells, and the parts of the package.
//!
//! Everything is kept in memory until the workbook is written. Writing
//! builds one part at a time (a name and its XML) and hands it to a
//! `zip.Packager`, in this order:
//!
//!     [Content_Types].xml          the type of every part
//!     _rels/.rels                  points at the workbook part
//!     xl/workbook.xml              sheet names, the filter ranges
//!     xl/_rels/workbook.xml.rels   where each sheet, styles and strings live
//!     xl/worksheets/sheetN.xml     one per sheet: columns, rows, cells
//!     xl/styles.xml                the formats cells point to
//!     xl/sharedStrings.xml         the texts cells point to (if any)
//!
//! No theme and no document properties are written.
//!
//! Reading and streamed writing are not implemented. See the README
//! ("Design notes") for how they fit this layout.

const std = @import("std");
const Writer = std.Io.Writer;
const zip = @import("zip.zig");
const xml = @import("xml.zig");
const cell_ref = @import("cell_ref.zig");
const date_mod = @import("date.zig");
const styles_mod = @import("styles.zig");
const shared_strings = @import("shared_strings.zig");

pub const Date = date_mod.Date;
pub const DateTime = date_mod.DateTime;
pub const Style = styles_mod.Style;
pub const Range = cell_ref.Range;

pub const Error = error{
    /// Row index past the last row of a sheet (1,048,576 rows).
    RowOutOfRange,
    /// Column index past the last column of a sheet (16,384 columns).
    ColumnOutOfRange,
    /// A range whose last row or column comes before its first.
    InvalidRange,
    /// Cell text longer than 32,767 characters.
    TextTooLong,
    /// Text, a sheet name or a formula that is not valid UTF-8.
    InvalidUtf8,
    /// NaN or infinity: a cell cannot hold them.
    InvalidNumber,
    /// Not a calendar date, or outside 1900-01-01 .. 9999-12-31.
    InvalidDate,
    /// An empty formula, one longer than 8,192 characters, or one with
    /// characters XML cannot carry.
    InvalidFormula,
    /// A sheet name Excel refuses (see `Workbook.addSheet`).
    InvalidSheetName,
    /// A sheet with this name already exists.
    DuplicateSheetName,
    /// A column width outside 0 .. 255.
    InvalidColumnWidth,
    /// A row height outside 0 .. 409 points.
    InvalidRowHeight,
    /// A merged range that shares a cell with another one.
    OverlappingMerge,
    /// A zoom outside 10 .. 400 percent.
    InvalidZoom,
    /// A custom number format that is empty, too long or malformed.
    InvalidNumberFormat,
    /// A font name that is empty, too long or malformed, or a font size
    /// outside 1 .. 409 points.
    InvalidFont,
    /// More than 65,490 distinct styles.
    TooManyStyles,
    /// A workbook must have at least one sheet to be written.
    NoSheets,
    /// The package does not fit a plain zip archive (zip64 is not
    /// implemented): a part or the whole file passes 4 GiB.
    ArchiveTooLarge,
    /// Only reachable with a custom `Packager`: this module's own part
    /// names are always valid and distinct.
    InvalidPartName,
    DuplicatePartName,
    OutOfMemory,
    /// The destination writer failed.
    WriteFailed,
};

/// Excel's limits, enforced when a value is set.
pub const max_rows = cell_ref.max_rows;
pub const max_cols = cell_ref.max_cols;
/// Characters per cell, counted as Excel does (UTF-16 code units).
pub const max_text_len = 32_767;
pub const max_formula_len = 8_192;
pub const max_sheet_name_len = 31;
pub const max_column_width = 255;
/// Row height, in points.
pub const max_row_height = 409;

/// What a cell holds.
pub const Value = union(enum) {
    /// No value. With a style, the cell is still written (an empty cell
    /// with a background, for instance).
    blank,
    /// Text, written exactly as given. Text is never interpreted: a
    /// string that starts with `=`, `+`, `-` or `@` stays text and is
    /// shown as typed. An empty string is the same as `blank`.
    text: []const u8,
    /// Numbers are IEEE doubles, as in every spreadsheet: integers are
    /// exact up to 2^53 and Excel shows 15 significant digits.
    number: f64,
    boolean: bool,
    /// Stored as a number; shown as a date because the cell gets the
    /// `date` number format unless the style names another one.
    date: Date,
    /// Like `date`, with the `datetime` number format by default.
    datetime: DateTime,
    /// A formula in Excel's syntax with English function names and `,`
    /// between arguments, e.g. `"SUM(B2:B9)"`. A leading `=` is
    /// accepted and dropped. No result is stored: the program opening
    /// the file calculates it. Never build a formula from user input.
    formula: []const u8,

    /// A whole number.
    pub fn int(n: anytype) Value {
        return .{ .number = @floatFromInt(n) };
    }
};

const Stored = union(enum) {
    blank,
    number: f64,
    /// An id in the workbook's shared strings table.
    string: u32,
    boolean: bool,
    formula: []const u8,
};

const Cell = struct {
    row: u32,
    col: u16,
    /// An id in the workbook's style registry (0 is the default style).
    style: u16,
    value: Stored,

    fn before(_: void, a: Cell, b: Cell) bool {
        return if (a.row != b.row) a.row < b.row else a.col < b.col;
    }
};

const ColumnWidth = struct {
    col: u16,
    width: f64,

    fn before(_: void, a: ColumnWidth, b: ColumnWidth) bool {
        return a.col < b.col;
    }
};

const RowHeight = struct {
    row: u32,
    height: f64,

    fn before(_: void, a: RowHeight, b: RowHeight) bool {
        return a.row < b.row;
    }
};

/// One sheet of a workbook. Created by `Workbook.addSheet`; rows and
/// columns are zero-based.
pub const Sheet = struct {
    workbook: *Workbook,
    name: []const u8,
    cells: std.ArrayList(Cell) = .empty,
    /// False once a cell was set out of row/column order or twice.
    cells_in_order: bool = true,
    column_widths: std.ArrayList(ColumnWidth) = .empty,
    row_heights: std.ArrayList(RowHeight) = .empty,
    merges: std.ArrayList(Range) = .empty,
    frozen_rows: u32 = 0,
    frozen_cols: u32 = 0,
    auto_filter: ?Range = null,
    /// In percent.
    zoom: u16 = 100,

    /// Sets a cell with the default style. Cells may be set in any
    /// order; setting a cell again replaces it.
    pub fn set(self: *Sheet, row: u32, col: u32, value: Value) Error!void {
        return self.setStyled(row, col, value, .{});
    }

    /// Sets a cell and its style.
    pub fn setStyled(self: *Sheet, row: u32, col: u32, value: Value, style: Style) Error!void {
        if (row >= max_rows) return error.RowOutOfRange;
        if (col >= max_cols) return error.ColumnOutOfRange;
        const workbook = self.workbook;
        const arena = workbook.arena.allocator();

        var effective_style = style;
        const stored: Stored = switch (value) {
            .blank => .blank,
            .text => |text| stored: {
                try checkText(text, max_text_len, error.TextTooLong);
                if (text.len == 0) break :stored .blank;
                break :stored .{ .string = try workbook.strings.intern(arena, text) };
            },
            .number => |n| if (std.math.isFinite(n)) .{ .number = n } else return error.InvalidNumber,
            .boolean => |b| .{ .boolean = b },
            .date => |d| stored: {
                if (style.number_format == .general) effective_style.number_format = .date;
                break :stored .{ .number = @floatFromInt(try d.serial()) };
            },
            .datetime => |dt| stored: {
                if (style.number_format == .general) effective_style.number_format = .datetime;
                break :stored .{ .number = try dt.serial() };
            },
            .formula => |formula| stored: {
                const body = if (std.mem.startsWith(u8, formula, "=")) formula[1..] else formula;
                if (body.len == 0) return error.InvalidFormula;
                try checkText(body, max_formula_len, error.InvalidFormula);
                if (!xml.isXmlSafe(body)) return error.InvalidFormula;
                workbook.has_formulas = true;
                break :stored .{ .formula = try arena.dupe(u8, body) };
            },
        };
        const style_id = try workbook.styles.intern(arena, effective_style);

        if (self.cells.items.len > 0) {
            const last = self.cells.items[self.cells.items.len - 1];
            if (row < last.row or (row == last.row and col <= last.col)) self.cells_in_order = false;
        }
        try self.cells.append(arena, .{ .row = row, .col = @intCast(col), .style = style_id, .value = stored });
    }

    /// Sets consecutive cells of one row, starting at `first_col`, all
    /// with the same style.
    pub fn setRow(self: *Sheet, row: u32, first_col: u32, values: []const Value, style: Style) Error!void {
        if (values.len > max_cols - @min(first_col, max_cols)) return error.ColumnOutOfRange;
        for (values, 0..) |value, i| {
            try self.setStyled(row, first_col + @as(u32, @intCast(i)), value, style);
        }
    }

    /// Sets a column's width, in characters of the default font (the
    /// unit Excel shows in its "Column width" dialog). 0 hides nothing
    /// but makes the column as narrow as possible.
    pub fn setColumnWidth(self: *Sheet, col: u32, width: f64) Error!void {
        if (col >= max_cols) return error.ColumnOutOfRange;
        if (!std.math.isFinite(width) or width < 0 or width > max_column_width) return error.InvalidColumnWidth;
        try self.column_widths.append(self.workbook.arena.allocator(), .{ .col = @intCast(col), .width = width });
    }

    /// Sets a row's height in points (a default row is 15). Without it
    /// a spreadsheet program sizes the row to its content when it draws
    /// the sheet, wrapped text included.
    pub fn setRowHeight(self: *Sheet, row: u32, points: f64) Error!void {
        if (row >= max_rows) return error.RowOutOfRange;
        if (!std.math.isFinite(points) or points < 0 or points > max_row_height) return error.InvalidRowHeight;
        try self.row_heights.append(self.workbook.arena.allocator(), .{ .row = row, .height = points });
    }

    /// Merges a rectangle of cells into one. The merged cell shows the
    /// value and the alignment of the range's top-left cell; borders and
    /// fills still come from each cell of the range, so style them all
    /// (blank cells with a style) to frame the merged cell.
    ///
    /// The range must cover more than one cell and cannot share a cell
    /// with another merged range.
    pub fn mergeCells(self: *Sheet, range: Range) Error!void {
        if (range.first_row >= max_rows or range.last_row >= max_rows) return error.RowOutOfRange;
        if (range.first_col >= max_cols or range.last_col >= max_cols) return error.ColumnOutOfRange;
        if (range.last_row < range.first_row or range.last_col < range.first_col) return error.InvalidRange;
        if (range.first_row == range.last_row and range.first_col == range.last_col) return error.InvalidRange;
        for (self.merges.items) |other| {
            const apart = range.last_row < other.first_row or other.last_row < range.first_row or
                range.last_col < other.first_col or other.last_col < range.first_col;
            if (!apart) return error.OverlappingMerge;
        }
        try self.merges.append(self.workbook.arena.allocator(), range);
    }

    /// Keeps the first `rows` rows and the first `cols` columns in view
    /// while the rest scrolls. `freeze(1, 0)` pins a header row.
    pub fn freeze(self: *Sheet, rows: u32, cols: u32) Error!void {
        if (rows >= max_rows) return error.RowOutOfRange;
        if (cols >= max_cols) return error.ColumnOutOfRange;
        self.frozen_rows = rows;
        self.frozen_cols = cols;
    }

    /// Sets the zoom the sheet opens with, 10 to 400 percent. It only
    /// affects the screen, not printing.
    pub fn setZoom(self: *Sheet, percent: u16) Error!void {
        if (percent < 10 or percent > 400) return error.InvalidZoom;
        self.zoom = percent;
    }

    /// Turns `range` into a filtered table: its first row gets the
    /// filter buttons. One filter per sheet; calling again replaces it.
    pub fn setAutoFilter(self: *Sheet, range: Range) Error!void {
        if (range.first_row >= max_rows or range.last_row >= max_rows) return error.RowOutOfRange;
        if (range.first_col >= max_cols or range.last_col >= max_cols) return error.ColumnOutOfRange;
        if (range.last_row < range.first_row or range.last_col < range.first_col) return error.InvalidRange;
        self.auto_filter = range;
    }

    /// Puts cells and column widths in file order and keeps the last
    /// write of each. Idempotent.
    fn normalize(self: *Sheet) void {
        if (!self.cells_in_order) {
            // A stable sort: equal positions stay in the order they
            // were set, so the last one is the one to keep.
            std.mem.sort(Cell, self.cells.items, {}, Cell.before);
            var kept: usize = 0;
            for (self.cells.items, 0..) |cell, i| {
                const superseded = i + 1 < self.cells.items.len and
                    self.cells.items[i + 1].row == cell.row and self.cells.items[i + 1].col == cell.col;
                if (superseded) continue;
                self.cells.items[kept] = cell;
                kept += 1;
            }
            self.cells.shrinkRetainingCapacity(kept);
            self.cells_in_order = true;
        }

        std.mem.sort(ColumnWidth, self.column_widths.items, {}, ColumnWidth.before);
        var kept: usize = 0;
        for (self.column_widths.items, 0..) |width, i| {
            const superseded = i + 1 < self.column_widths.items.len and self.column_widths.items[i + 1].col == width.col;
            if (superseded) continue;
            self.column_widths.items[kept] = width;
            kept += 1;
        }
        self.column_widths.shrinkRetainingCapacity(kept);

        std.mem.sort(RowHeight, self.row_heights.items, {}, RowHeight.before);
        kept = 0;
        for (self.row_heights.items, 0..) |height, i| {
            const superseded = i + 1 < self.row_heights.items.len and self.row_heights.items[i + 1].row == height.row;
            if (superseded) continue;
            self.row_heights.items[kept] = height;
            kept += 1;
        }
        self.row_heights.shrinkRetainingCapacity(kept);
    }
};

/// A workbook being built. Not thread-safe; there is no global state,
/// so separate workbooks can be built on separate threads.
pub const Workbook = struct {
    gpa: std.mem.Allocator,
    /// Owns everything the workbook keeps: sheets, cells, copied text.
    arena: std.heap.ArenaAllocator,
    sheets: std.ArrayList(*Sheet) = .empty,
    strings: shared_strings.Table = .{},
    styles: styles_mod.Registry = .{},
    has_formulas: bool = false,

    /// Creates an empty workbook. All memory comes from `gpa` and is
    /// released by `deinit`. Text passed in is copied: the caller's
    /// buffers can be freed or reused right after each call.
    pub fn init(gpa: std.mem.Allocator) error{OutOfMemory}!*Workbook {
        const self = try gpa.create(Workbook);
        self.* = .{ .gpa = gpa, .arena = .init(gpa) };
        return self;
    }

    pub fn deinit(self: *Workbook) void {
        const gpa = self.gpa;
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// Adds a sheet; sheets appear in the order they are added.
    ///
    /// The name follows Excel's rules: 1 to 31 characters, none of
    /// `/ \ ? * : [ ]`, no control characters, no apostrophe at either
    /// end, not "History", and different from the other sheets' names
    /// whatever the case of ASCII letters.
    pub fn addSheet(self: *Workbook, name: []const u8) Error!*Sheet {
        try checkSheetName(name);
        for (self.sheets.items) |sheet| {
            if (std.ascii.eqlIgnoreCase(sheet.name, name)) return error.DuplicateSheetName;
        }
        const arena = self.arena.allocator();
        const sheet = try arena.create(Sheet);
        sheet.* = .{ .workbook = self, .name = try arena.dupe(u8, name) };
        try self.sheets.append(arena, sheet);
        return sheet;
    }

    /// Writes the .xlsx file to `out`. `out` is not flushed: flush it
    /// afterwards if it is buffered. The workbook can be written more
    /// than once, and always produces the same bytes.
    pub fn writeTo(self: *Workbook, out: *Writer) Error!void {
        var archive: zip.StoreZip = .init(self.gpa, out);
        defer archive.deinit();
        try self.writeToPackager(archive.packager());
    }

    /// Returns the .xlsx file as bytes owned by the caller (free them
    /// with `allocator`).
    pub fn toOwnedSlice(self: *Workbook, allocator: std.mem.Allocator) Error![]u8 {
        var out: Writer.Allocating = .init(allocator);
        defer out.deinit();
        self.writeTo(&out.writer) catch |err| switch (err) {
            // The only way an allocating writer fails.
            error.WriteFailed => return error.OutOfMemory,
            else => |e| return e,
        };
        return out.toOwnedSlice();
    }

    /// Hands every part to `packager` and finishes it. This is the seam
    /// for another container (a compressing zip, a recorder in tests).
    pub fn writeToPackager(self: *Workbook, packager: zip.Packager) Error!void {
        if (self.sheets.items.len == 0) return error.NoSheets;
        const gpa = self.gpa;
        for (self.sheets.items) |sheet| sheet.normalize();

        // Which styles and strings ended up used, in the order a reader
        // meets them. `style_records[id]` is the cell's `s` value and
        // `string_indexes[id]` its `<v>`.
        const style_records = try gpa.alloc(u32, self.styles.count());
        defer gpa.free(style_records);
        @memset(style_records, 0);
        var used_styles: std.ArrayList(u16) = .empty;
        defer used_styles.deinit(gpa);

        const unused = std.math.maxInt(u32);
        const string_indexes = try gpa.alloc(u32, self.strings.count());
        defer gpa.free(string_indexes);
        @memset(string_indexes, unused);
        var used_strings: std.ArrayList([]const u8) = .empty;
        defer used_strings.deinit(gpa);
        var string_references: u64 = 0;

        for (self.sheets.items) |sheet| {
            for (sheet.cells.items) |cell| {
                if (cell.style != 0 and style_records[cell.style] == 0) {
                    try used_styles.append(gpa, cell.style);
                    style_records[cell.style] = @intCast(used_styles.items.len);
                }
                switch (cell.value) {
                    .string => |id| {
                        if (string_indexes[id] == unused) {
                            string_indexes[id] = @intCast(used_strings.items.len);
                            try used_strings.append(gpa, self.strings.get(id));
                        }
                        string_references += 1;
                    },
                    else => {},
                }
            }
        }
        const has_strings = used_strings.items.len > 0;

        // Each part is built in this buffer, then handed over. A
        // streaming packager would instead be given a writer per part;
        // the part functions below already only need a `*Writer`.
        var part: Writer.Allocating = .init(gpa);
        defer part.deinit();
        const w = &part.writer;

        writeContentTypes(w, self.sheets.items.len, has_strings) catch return error.OutOfMemory;
        try packager.addPart("[Content_Types].xml", part.written());

        part.clearRetainingCapacity();
        writeRootRelationships(w) catch return error.OutOfMemory;
        try packager.addPart("_rels/.rels", part.written());

        part.clearRetainingCapacity();
        self.writeWorkbookPart(w) catch return error.OutOfMemory;
        try packager.addPart("xl/workbook.xml", part.written());

        part.clearRetainingCapacity();
        writeWorkbookRelationships(w, self.sheets.items.len, has_strings) catch return error.OutOfMemory;
        try packager.addPart("xl/_rels/workbook.xml.rels", part.written());

        for (self.sheets.items, 0..) |sheet, index| {
            part.clearRetainingCapacity();
            writeSheetPart(w, sheet, index == 0, style_records, string_indexes) catch return error.OutOfMemory;
            var name_buffer: [48]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buffer, "xl/worksheets/sheet{d}.xml", .{index + 1}) catch unreachable;
            try packager.addPart(name, part.written());
        }

        part.clearRetainingCapacity();
        self.styles.write(w, gpa, used_styles.items) catch return error.OutOfMemory;
        try packager.addPart("xl/styles.xml", part.written());

        if (has_strings) {
            part.clearRetainingCapacity();
            shared_strings.write(w, used_strings.items, string_references) catch return error.OutOfMemory;
            try packager.addPart("xl/sharedStrings.xml", part.written());
        }

        try packager.finish();
    }

    fn writeWorkbookPart(self: *const Workbook, w: *Writer) Writer.Error!void {
        try w.writeAll(xml.declaration);
        try w.writeAll("<workbook xmlns=\"" ++ ns_main ++ "\" xmlns:r=\"" ++ ns_relationships ++ "\">");
        try w.writeAll("<bookViews><workbookView/></bookViews>");

        try w.writeAll("<sheets>");
        for (self.sheets.items, 1..) |sheet, number| {
            try w.writeAll("<sheet name=\"");
            try xml.writeAttribute(w, sheet.name);
            try w.print("\" sheetId=\"{d}\" r:id=\"rId{d}\"/>", .{ number, number });
        }
        try w.writeAll("</sheets>");

        // A filter only works in Excel if the workbook also names its
        // range with this hidden, per-sheet defined name.
        var any_filter = false;
        for (self.sheets.items, 0..) |sheet, index| {
            const range = sheet.auto_filter orelse continue;
            if (!any_filter) try w.writeAll("<definedNames>");
            any_filter = true;
            try w.print("<definedName name=\"_xlnm._FilterDatabase\" localSheetId=\"{d}\" hidden=\"1\">", .{index});
            try writeQuotedSheetName(w, sheet.name);
            try w.writeByte('!');
            try range.writeAbsolute(w);
            try w.writeAll("</definedName>");
        }
        if (any_filter) try w.writeAll("</definedNames>");

        // Formulas are written without results: ask for a calculation
        // when the file is opened.
        if (self.has_formulas) try w.writeAll("<calcPr fullCalcOnLoad=\"1\"/>");
        try w.writeAll("</workbook>");
    }
};

const ns_main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
const ns_relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
const ns_package_relationships = "http://schemas.openxmlformats.org/package/2006/relationships";
const type_prefix = "application/vnd.openxmlformats-officedocument.spreadsheetml.";

fn writeContentTypes(w: *Writer, sheet_count: usize, has_strings: bool) Writer.Error!void {
    try w.writeAll(xml.declaration);
    try w.writeAll("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">");
    try w.writeAll("<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>");
    try w.writeAll("<Default Extension=\"xml\" ContentType=\"application/xml\"/>");
    try w.writeAll("<Override PartName=\"/xl/workbook.xml\" ContentType=\"" ++ type_prefix ++ "sheet.main+xml\"/>");
    for (1..sheet_count + 1) |number| {
        try w.print("<Override PartName=\"/xl/worksheets/sheet{d}.xml\" ContentType=\"" ++ type_prefix ++ "worksheet+xml\"/>", .{number});
    }
    try w.writeAll("<Override PartName=\"/xl/styles.xml\" ContentType=\"" ++ type_prefix ++ "styles+xml\"/>");
    if (has_strings) {
        try w.writeAll("<Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"" ++ type_prefix ++ "sharedStrings+xml\"/>");
    }
    try w.writeAll("</Types>");
}

fn writeRootRelationships(w: *Writer) Writer.Error!void {
    try w.writeAll(xml.declaration);
    try w.writeAll("<Relationships xmlns=\"" ++ ns_package_relationships ++ "\">");
    try w.writeAll("<Relationship Id=\"rId1\" Type=\"" ++ ns_relationships ++ "/officeDocument\" Target=\"xl/workbook.xml\"/>");
    try w.writeAll("</Relationships>");
}

fn writeWorkbookRelationships(w: *Writer, sheet_count: usize, has_strings: bool) Writer.Error!void {
    try w.writeAll(xml.declaration);
    try w.writeAll("<Relationships xmlns=\"" ++ ns_package_relationships ++ "\">");
    for (1..sheet_count + 1) |number| {
        try w.print("<Relationship Id=\"rId{d}\" Type=\"" ++ ns_relationships ++ "/worksheet\" Target=\"worksheets/sheet{d}.xml\"/>", .{ number, number });
    }
    try w.print("<Relationship Id=\"rId{d}\" Type=\"" ++ ns_relationships ++ "/styles\" Target=\"styles.xml\"/>", .{sheet_count + 1});
    if (has_strings) {
        try w.print("<Relationship Id=\"rId{d}\" Type=\"" ++ ns_relationships ++ "/sharedStrings\" Target=\"sharedStrings.xml\"/>", .{sheet_count + 2});
    }
    try w.writeAll("</Relationships>");
}

/// Writes a worksheet part. Element order is fixed by the format:
/// dimension, sheetViews, sheetFormatPr, cols, sheetData, autoFilter,
/// mergeCells.
fn writeSheetPart(w: *Writer, sheet: *const Sheet, selected: bool, style_records: []const u32, string_indexes: []const u32) Writer.Error!void {
    try w.writeAll(xml.declaration);
    try w.writeAll("<worksheet xmlns=\"" ++ ns_main ++ "\" xmlns:r=\"" ++ ns_relationships ++ "\">");

    // The used range. A cell with neither value nor style is not
    // written, so it does not count.
    var used: ?Range = null;
    for (sheet.cells.items) |cell| {
        if (isSkipped(cell)) continue;
        if (used) |*range| {
            range.first_row = @min(range.first_row, cell.row);
            range.last_row = @max(range.last_row, cell.row);
            range.first_col = @min(range.first_col, cell.col);
            range.last_col = @max(range.last_col, cell.col);
        } else {
            used = .{ .first_row = cell.row, .last_row = cell.row, .first_col = cell.col, .last_col = cell.col };
        }
    }
    try w.writeAll("<dimension ref=\"");
    if (used) |range| {
        if (range.first_row == range.last_row and range.first_col == range.last_col) {
            try cell_ref.writeCell(w, range.first_row, range.first_col);
        } else {
            try range.write(w);
        }
    } else try w.writeAll("A1");
    try w.writeAll("\"/>");

    try w.writeAll("<sheetViews><sheetView");
    if (selected) try w.writeAll(" tabSelected=\"1\"");
    if (sheet.zoom != 100) try w.print(" zoomScale=\"{d}\" zoomScaleNormal=\"{d}\"", .{ sheet.zoom, sheet.zoom });
    try w.writeAll(" workbookViewId=\"0\"");
    if (sheet.frozen_rows > 0 or sheet.frozen_cols > 0) {
        try w.writeAll("><pane");
        if (sheet.frozen_cols > 0) try w.print(" xSplit=\"{d}\"", .{sheet.frozen_cols});
        if (sheet.frozen_rows > 0) try w.print(" ySplit=\"{d}\"", .{sheet.frozen_rows});
        try w.writeAll(" topLeftCell=\"");
        try cell_ref.writeCell(w, sheet.frozen_rows, sheet.frozen_cols);
        const active_pane = if (sheet.frozen_rows > 0 and sheet.frozen_cols > 0)
            "bottomRight"
        else if (sheet.frozen_rows > 0)
            "bottomLeft"
        else
            "topRight";
        try w.print("\" activePane=\"{s}\" state=\"frozen\"/><selection pane=\"{s}\"/></sheetView>", .{ active_pane, active_pane });
    } else try w.writeAll("/>");
    try w.writeAll("</sheetViews>");

    try w.writeAll("<sheetFormatPr defaultRowHeight=\"15\"/>");

    if (sheet.column_widths.items.len > 0) {
        try w.writeAll("<cols>");
        for (sheet.column_widths.items) |column| {
            const number = @as(u32, column.col) + 1;
            try w.print("<col min=\"{d}\" max=\"{d}\" width=\"{d}\" customWidth=\"1\"/>", .{ number, number, fileColumnWidth(column.width) });
        }
        try w.writeAll("</cols>");
    }

    try w.writeAll("<sheetData>");
    // Rows come from two sorted lists: the cells, and the rows that
    // were given a height (which may have no cell at all).
    var heights = sheet.row_heights.items;
    var open_row: ?u32 = null;
    for (sheet.cells.items) |cell| {
        if (isSkipped(cell)) continue;
        if (open_row != cell.row) {
            if (open_row != null) try w.writeAll("</row>");
            while (heights.len > 0 and heights[0].row < cell.row) : (heights = heights[1..]) {
                try w.print("<row r=\"{d}\" ht=\"{d}\" customHeight=\"1\"/>", .{ heights[0].row + 1, heights[0].height });
            }
            try w.print("<row r=\"{d}\"", .{cell.row + 1});
            if (heights.len > 0 and heights[0].row == cell.row) {
                try w.print(" ht=\"{d}\" customHeight=\"1\"", .{heights[0].height});
                heights = heights[1..];
            }
            try w.writeByte('>');
            open_row = cell.row;
        }
        try w.writeAll("<c r=\"");
        try cell_ref.writeCell(w, cell.row, cell.col);
        try w.writeByte('"');
        if (cell.style != 0) try w.print(" s=\"{d}\"", .{style_records[cell.style]});
        switch (cell.value) {
            .blank => try w.writeAll("/>"),
            .number => |n| try w.print("><v>{d}</v></c>", .{n}),
            .string => |id| try w.print(" t=\"s\"><v>{d}</v></c>", .{string_indexes[id]}),
            .boolean => |b| try w.print(" t=\"b\"><v>{d}</v></c>", .{@intFromBool(b)}),
            .formula => |formula| {
                try w.writeAll("><f>");
                try xml.writeText(w, formula);
                try w.writeAll("</f></c>");
            },
        }
    }
    if (open_row != null) try w.writeAll("</row>");
    for (heights) |height| {
        try w.print("<row r=\"{d}\" ht=\"{d}\" customHeight=\"1\"/>", .{ height.row + 1, height.height });
    }
    try w.writeAll("</sheetData>");

    if (sheet.auto_filter) |range| {
        try w.writeAll("<autoFilter ref=\"");
        try range.write(w);
        try w.writeAll("\"/>");
    }
    if (sheet.merges.items.len > 0) {
        try w.print("<mergeCells count=\"{d}\">", .{sheet.merges.items.len});
        for (sheet.merges.items) |range| {
            try w.writeAll("<mergeCell ref=\"");
            try range.write(w);
            try w.writeAll("\"/>");
        }
        try w.writeAll("</mergeCells>");
    }
    try w.writeAll("</worksheet>");
}

fn isSkipped(cell: Cell) bool {
    return cell.value == .blank and cell.style == 0;
}

/// Converts a width in characters to the value stored in the file,
/// which includes the cell padding and is rounded to 1/256 of a
/// character. Uses the metrics of the default font (Calibri 11: digits
/// 7 pixels wide, 5 pixels of padding), like Excel does.
fn fileColumnWidth(characters: f64) f64 {
    const max_digit_width = 7.0;
    const padding = 5.0;
    const pixels = if (characters >= 1)
        @trunc(characters * max_digit_width + 0.5) + padding
    else
        @trunc(characters * (max_digit_width + padding) + 0.5);
    return @trunc(pixels / max_digit_width * 256.0) / 256.0;
}

/// `'Name'`, with apostrophes doubled: how a sheet is named inside a
/// reference. Quoting is always valid, so it is not made conditional.
fn writeQuotedSheetName(w: *Writer, name: []const u8) Writer.Error!void {
    try w.writeByte('\'');
    var rest = name;
    while (std.mem.indexOfScalar(u8, rest, '\'')) |at| {
        try xml.writeText(w, rest[0..at]);
        try w.writeAll("''");
        rest = rest[at + 1 ..];
    }
    try xml.writeText(w, rest);
    try w.writeByte('\'');
}

/// Checks UTF-8 and the length in UTF-16 code units (what Excel
/// counts).
fn checkText(text: []const u8, max_len: usize, comptime too_long: Error) Error!void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (utf16Len(text) > max_len) return too_long;
}

/// Length in UTF-16 code units of valid UTF-8.
fn utf16Len(text: []const u8) usize {
    var len: usize = 0;
    for (text) |byte| {
        if (byte & 0xc0 != 0x80) len += 1; // not a continuation byte
        if (byte >= 0xf0) len += 1; // outside the BMP: a surrogate pair
    }
    return len;
}

fn checkSheetName(name: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidUtf8;
    const len = utf16Len(name);
    if (len == 0 or len > max_sheet_name_len) return error.InvalidSheetName;
    if (name[0] == '\'' or name[name.len - 1] == '\'') return error.InvalidSheetName;
    if (std.ascii.eqlIgnoreCase(name, "History")) return error.InvalidSheetName;
    if (!xml.isXmlSafe(name)) return error.InvalidSheetName;
    for (name) |c| switch (c) {
        '/', '\\', '?', '*', ':', '[', ']' => return error.InvalidSheetName,
        0x00...0x1f => return error.InvalidSheetName,
        else => {},
    };
}

const testing = std.testing;

/// A packager that keeps the parts instead of writing an archive.
const Recorder = struct {
    arena: std.heap.ArenaAllocator,
    names: std.ArrayList([]const u8) = .empty,
    contents: std.ArrayList([]const u8) = .empty,
    finished: bool = false,

    fn init() Recorder {
        return .{ .arena = .init(testing.allocator) };
    }

    fn deinit(self: *Recorder) void {
        self.arena.deinit();
    }

    fn packager(self: *Recorder) zip.Packager {
        return .{ .ptr = self, .vtable = &.{ .addPart = addPart, .finish = finish } };
    }

    fn addPart(ptr: *anyopaque, name: []const u8, content: []const u8) zip.Error!void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        const arena = self.arena.allocator();
        try self.names.append(arena, try arena.dupe(u8, name));
        try self.contents.append(arena, try arena.dupe(u8, content));
    }

    fn finish(ptr: *anyopaque) zip.Error!void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        self.finished = true;
    }

    fn part(self: *const Recorder, name: []const u8) ?[]const u8 {
        for (self.names.items, self.contents.items) |candidate, content| {
            if (std.mem.eql(u8, candidate, name)) return content;
        }
        return null;
    }

    fn expectNames(self: *const Recorder, expected: []const []const u8) !void {
        try testing.expectEqual(expected.len, self.names.items.len);
        for (expected, self.names.items) |want, got| try testing.expectEqualStrings(want, got);
    }
};

const worksheet_open = xml.declaration ++ "<worksheet xmlns=\"" ++ ns_main ++ "\" xmlns:r=\"" ++ ns_relationships ++ "\">";
const workbook_open = xml.declaration ++ "<workbook xmlns=\"" ++ ns_main ++ "\" xmlns:r=\"" ++ ns_relationships ++ "\">";

test "the smallest workbook: one empty sheet, six parts" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    _ = try wb.addSheet("Sheet1");

    var recorder: Recorder = .init();
    defer recorder.deinit();
    try wb.writeToPackager(recorder.packager());
    try testing.expect(recorder.finished);

    try recorder.expectNames(&.{
        "[Content_Types].xml",
        "_rels/.rels",
        "xl/workbook.xml",
        "xl/_rels/workbook.xml.rels",
        "xl/worksheets/sheet1.xml",
        "xl/styles.xml",
    });

    try testing.expectEqualStrings(xml.declaration ++
        "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" ++
        "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" ++
        "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" ++
        "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>" ++
        "<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" ++
        "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>" ++
        "</Types>", recorder.part("[Content_Types].xml").?);

    try testing.expectEqualStrings(xml.declaration ++
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" ++
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>" ++
        "</Relationships>", recorder.part("_rels/.rels").?);

    try testing.expectEqualStrings(workbook_open ++
        "<bookViews><workbookView/></bookViews>" ++
        "<sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets>" ++
        "</workbook>", recorder.part("xl/workbook.xml").?);

    try testing.expectEqualStrings(xml.declaration ++
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" ++
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>" ++
        "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>" ++
        "</Relationships>", recorder.part("xl/_rels/workbook.xml.rels").?);

    try testing.expectEqualStrings(worksheet_open ++
        "<dimension ref=\"A1\"/>" ++
        "<sheetViews><sheetView tabSelected=\"1\" workbookViewId=\"0\"/></sheetViews>" ++
        "<sheetFormatPr defaultRowHeight=\"15\"/>" ++
        "<sheetData></sheetData>" ++
        "</worksheet>", recorder.part("xl/worksheets/sheet1.xml").?);
}

/// The workbook most tests below look at: every kind of value, styles,
/// a column width, a frozen header and a filter, on two sheets.
fn buildSample(gpa: std.mem.Allocator) Error!*Workbook {
    const wb = try Workbook.init(gpa);
    errdefer wb.deinit();

    const result = try wb.addSheet("Resultado");
    try result.setColumnWidth(0, 30);
    const header: Style = .{ .bold = true, .fill = 0xDDEEFF, .border = .thin };
    try result.setRow(0, 0, &.{ .{ .text = "Opção" }, .{ .text = "Votos" }, .{ .text = "%" } }, header);
    try result.set(1, 0, .{ .text = "Sim" });
    try result.set(1, 1, .int(12));
    try result.setStyled(1, 2, .{ .number = 0.75 }, .{ .number_format = .percent });
    try result.set(2, 0, .{ .text = "Não" });
    try result.set(2, 1, .int(4));
    try result.setStyled(2, 2, .{ .number = 0.25 }, .{ .number_format = .percent });
    try result.set(3, 0, .{ .text = "Total" });
    try result.set(3, 1, .{ .formula = "=SUM(B2:B3)" });
    try result.set(3, 3, .{ .boolean = true });
    try result.set(4, 0, .{ .date = .{ .year = 2026, .month = 10, .day = 7 } });
    try result.set(4, 1, .{ .datetime = .{ .year = 2026, .month = 10, .day = 7, .hour = 12 } });
    try result.freeze(1, 0);
    try result.setAutoFilter(.{ .first_row = 0, .first_col = 0, .last_row = 2, .last_col = 2 });

    const votes = try wb.addSheet("Votos d'água");
    try votes.setRow(0, 0, &.{ .{ .text = "Unidade" }, .{ .text = "Opção" } }, header);
    try votes.setRow(1, 0, &.{ .{ .text = "101" }, .{ .text = "Sim" } }, .{});
    try votes.freeze(1, 1);
    try votes.setAutoFilter(.{ .first_row = 0, .first_col = 0, .last_row = 1, .last_col = 1 });
    return wb;
}

test "a full workbook: the XML of each part" {
    const wb = try buildSample(testing.allocator);
    defer wb.deinit();
    var recorder: Recorder = .init();
    defer recorder.deinit();
    try wb.writeToPackager(recorder.packager());

    try recorder.expectNames(&.{
        "[Content_Types].xml",
        "_rels/.rels",
        "xl/workbook.xml",
        "xl/_rels/workbook.xml.rels",
        "xl/worksheets/sheet1.xml",
        "xl/worksheets/sheet2.xml",
        "xl/styles.xml",
        "xl/sharedStrings.xml",
    });

    try testing.expectEqualStrings(workbook_open ++
        "<bookViews><workbookView/></bookViews>" ++
        "<sheets><sheet name=\"Resultado\" sheetId=\"1\" r:id=\"rId1\"/>" ++
        "<sheet name=\"Votos d'água\" sheetId=\"2\" r:id=\"rId2\"/></sheets>" ++
        "<definedNames>" ++
        "<definedName name=\"_xlnm._FilterDatabase\" localSheetId=\"0\" hidden=\"1\">'Resultado'!$A$1:$C$3</definedName>" ++
        "<definedName name=\"_xlnm._FilterDatabase\" localSheetId=\"1\" hidden=\"1\">'Votos d''água'!$A$1:$B$2</definedName>" ++
        "</definedNames>" ++
        "<calcPr fullCalcOnLoad=\"1\"/>" ++
        "</workbook>", recorder.part("xl/workbook.xml").?);

    try testing.expectEqualStrings(worksheet_open ++
        "<dimension ref=\"A1:D5\"/>" ++
        "<sheetViews><sheetView tabSelected=\"1\" workbookViewId=\"0\">" ++
        "<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/><selection pane=\"bottomLeft\"/>" ++
        "</sheetView></sheetViews>" ++
        "<sheetFormatPr defaultRowHeight=\"15\"/>" ++
        "<cols><col min=\"1\" max=\"1\" width=\"30.7109375\" customWidth=\"1\"/></cols>" ++
        "<sheetData>" ++
        "<row r=\"1\"><c r=\"A1\" s=\"1\" t=\"s\"><v>0</v></c><c r=\"B1\" s=\"1\" t=\"s\"><v>1</v></c><c r=\"C1\" s=\"1\" t=\"s\"><v>2</v></c></row>" ++
        "<row r=\"2\"><c r=\"A2\" t=\"s\"><v>3</v></c><c r=\"B2\"><v>12</v></c><c r=\"C2\" s=\"2\"><v>0.75</v></c></row>" ++
        "<row r=\"3\"><c r=\"A3\" t=\"s\"><v>4</v></c><c r=\"B3\"><v>4</v></c><c r=\"C3\" s=\"2\"><v>0.25</v></c></row>" ++
        "<row r=\"4\"><c r=\"A4\" t=\"s\"><v>5</v></c><c r=\"B4\"><f>SUM(B2:B3)</f></c><c r=\"D4\" t=\"b\"><v>1</v></c></row>" ++
        "<row r=\"5\"><c r=\"A5\" s=\"3\"><v>46302</v></c><c r=\"B5\" s=\"4\"><v>46302.5</v></c></row>" ++
        "</sheetData>" ++
        "<autoFilter ref=\"A1:C3\"/>" ++
        "</worksheet>", recorder.part("xl/worksheets/sheet1.xml").?);

    try testing.expectEqualStrings(worksheet_open ++
        "<dimension ref=\"A1:B2\"/>" ++
        "<sheetViews><sheetView workbookViewId=\"0\">" ++
        "<pane xSplit=\"1\" ySplit=\"1\" topLeftCell=\"B2\" activePane=\"bottomRight\" state=\"frozen\"/><selection pane=\"bottomRight\"/>" ++
        "</sheetView></sheetViews>" ++
        "<sheetFormatPr defaultRowHeight=\"15\"/>" ++
        "<sheetData>" ++
        "<row r=\"1\"><c r=\"A1\" s=\"1\" t=\"s\"><v>6</v></c><c r=\"B1\" s=\"1\" t=\"s\"><v>0</v></c></row>" ++
        "<row r=\"2\"><c r=\"A2\" t=\"s\"><v>7</v></c><c r=\"B2\" t=\"s\"><v>3</v></c></row>" ++
        "</sheetData>" ++
        "<autoFilter ref=\"A1:B2\"/>" ++
        "</worksheet>", recorder.part("xl/worksheets/sheet2.xml").?);

    try testing.expectEqualStrings(xml.declaration ++
        "<sst xmlns=\"" ++ ns_main ++ "\" count=\"10\" uniqueCount=\"8\">" ++
        "<si><t>Opção</t></si><si><t>Votos</t></si><si><t>%</t></si><si><t>Sim</t></si>" ++
        "<si><t>Não</t></si><si><t>Total</t></si><si><t>Unidade</t></si><si><t>101</t></si>" ++
        "</sst>", recorder.part("xl/sharedStrings.xml").?);

    // Header, percent, date, date and time: four records after the default.
    const styles_xml = recorder.part("xl/styles.xml").?;
    try testing.expect(std.mem.indexOf(u8, styles_xml, "<cellXfs count=\"5\">" ++
        "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>" ++
        "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"2\" borderId=\"1\" xfId=\"0\" applyFont=\"1\" applyFill=\"1\" applyBorder=\"1\"/>" ++
        "<xf numFmtId=\"9\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>" ++
        "<xf numFmtId=\"14\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>" ++
        "<xf numFmtId=\"22\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>" ++
        "</cellXfs>") != null);

    const types = recorder.part("[Content_Types].xml").?;
    try testing.expect(std.mem.indexOf(u8, types, "/xl/worksheets/sheet2.xml") != null);
    try testing.expect(std.mem.indexOf(u8, types, "/xl/sharedStrings.xml") != null);
    const rels = recorder.part("xl/_rels/workbook.xml.rels").?;
    try testing.expect(std.mem.indexOf(u8, rels, "Id=\"rId3\" Type=\"" ++ ns_relationships ++ "/styles\"") != null);
    try testing.expect(std.mem.indexOf(u8, rels, "Id=\"rId4\" Type=\"" ++ ns_relationships ++ "/sharedStrings\"") != null);
}

fn sheetData(recorder: *const Recorder, part_name: []const u8) []const u8 {
    const content = recorder.part(part_name).?;
    const start = std.mem.indexOf(u8, content, "<sheetData>").? + "<sheetData>".len;
    const end = std.mem.indexOf(u8, content, "</sheetData>").?;
    return content[start..end];
}

test "text that looks like a formula stays text" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    const sheet = try wb.addSheet("Import");
    const hostile = [_][]const u8{ "=1+1", "=HYPERLINK(\"http://evil\",\"click\")", "+SUM(A1)", "-2+3", "@cmd", "\t=1", "=cmd|' /C calc'!A0" };
    for (hostile, 0..) |text, row| try sheet.set(@intCast(row), 0, .{ .text = text });

    var recorder: Recorder = .init();
    defer recorder.deinit();
    try wb.writeToPackager(recorder.packager());

    // Every cell is a shared string; nothing became a formula.
    const data = sheetData(&recorder, "xl/worksheets/sheet1.xml");
    try testing.expectEqual(hostile.len, std.mem.count(u8, data, " t=\"s\">"));
    try testing.expect(std.mem.indexOf(u8, data, "<f>") == null);
    try testing.expect(std.mem.indexOf(u8, recorder.part("xl/workbook.xml").?, "calcPr") == null);
    const strings = recorder.part("xl/sharedStrings.xml").?;
    try testing.expect(std.mem.indexOf(u8, strings, "<si><t>=1+1</t></si>") != null);
    try testing.expect(std.mem.indexOf(u8, strings, "<si><t>=HYPERLINK(\"http://evil\",\"click\")</t></si>") != null);
    try testing.expect(std.mem.indexOf(u8, strings, "<si><t xml:space=\"preserve\">\t=1</t></si>") != null);
}

test "formulas: the leading = is optional and markup is escaped" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    const sheet = try wb.addSheet("F");
    try sheet.set(0, 0, .{ .formula = "IF(A2<B2,\"a&b\",A2>0)" });
    try sheet.set(0, 1, .{ .formula = "=A1" });

    var recorder: Recorder = .init();
    defer recorder.deinit();
    try wb.writeToPackager(recorder.packager());
    try testing.expectEqualStrings("<row r=\"1\"><c r=\"A1\"><f>IF(A2&lt;B2,\"a&amp;b\",A2&gt;0)</f></c><c r=\"B1\"><f>A1</f></c></row>", sheetData(&recorder, "xl/worksheets/sheet1.xml"));
}

test "cells can be set in any order, and the last write wins" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    const sheet = try wb.addSheet("S");
    try sheet.set(2, 1, .int(5));
    try sheet.set(0, 2, .int(3));
    try sheet.set(0, 0, .int(1));
    try sheet.setStyled(2, 1, .{ .text = "replaced" }, .{ .bold = true });
    try sheet.set(2, 1, .int(6));
    try sheet.set(0, 1, .{ .text = "gone" });
    try sheet.set(0, 1, .blank);
    try sheet.setColumnWidth(1, 10);
    try sheet.setColumnWidth(0, 0.5);
    try sheet.setColumnWidth(1, 20);

    var recorder: Recorder = .init();
    defer recorder.deinit();
    try wb.writeToPackager(recorder.packager());
    try testing.expectEqualStrings("<row r=\"1\"><c r=\"A1\"><v>1</v></c><c r=\"C1\"><v>3</v></c></row>" ++
        "<row r=\"3\"><c r=\"B3\"><v>6</v></c></row>", sheetData(&recorder, "xl/worksheets/sheet1.xml"));

    const content = recorder.part("xl/worksheets/sheet1.xml").?;
    try testing.expect(std.mem.indexOf(u8, content, "<dimension ref=\"A1:C3\"/>") != null);
    try testing.expect(std.mem.indexOf(u8, content, "<cols><col min=\"1\" max=\"1\" width=\"0.85546875\" customWidth=\"1\"/>" ++
        "<col min=\"2\" max=\"2\" width=\"20.7109375\" customWidth=\"1\"/></cols>") != null);

    // The bold style and both texts were overwritten: neither is written.
    try testing.expect(recorder.part("xl/sharedStrings.xml") == null);
    try testing.expect(std.mem.indexOf(u8, recorder.part("xl/styles.xml").?, "<cellXfs count=\"1\">") != null);
    try testing.expect(std.mem.indexOf(u8, recorder.part("xl/styles.xml").?, "<fonts count=\"1\">") != null);
}

test "blank cells: written only when they carry a style" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    const sheet = try wb.addSheet("S");
    try sheet.set(0, 0, .blank);
    try sheet.set(0, 1, .{ .text = "" });
    try sheet.setStyled(0, 2, .blank, .{ .fill = 0xFFFF00 });
    try sheet.setStyled(9, 9, .{ .text = "" }, .{});

    var recorder: Recorder = .init();
    defer recorder.deinit();
    try wb.writeToPackager(recorder.packager());
    try testing.expectEqualStrings("<row r=\"1\"><c r=\"C1\" s=\"1\"/></row>", sheetData(&recorder, "xl/worksheets/sheet1.xml"));
    try testing.expect(std.mem.indexOf(u8, recorder.part("xl/worksheets/sheet1.xml").?, "<dimension ref=\"C1\"/>") != null);
    try testing.expect(recorder.part("xl/sharedStrings.xml") == null);
}

test "numbers are written in full, without exponent or locale" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    const sheet = try wb.addSheet("N");
    try sheet.setRow(0, 0, &.{
        .{ .number = 0 },
        .{ .number = -1.5 },
        .{ .number = 0.1 },
        .{ .number = 1234567.891 },
        .{ .number = 1e21 },
        .{ .number = 1e-7 },
        .int(9_007_199_254_740_992),
        .int(-42),
    }, .{});

    var recorder: Recorder = .init();
    defer recorder.deinit();
    try wb.writeToPackager(recorder.packager());
    try testing.expectEqualStrings("<row r=\"1\"><c r=\"A1\"><v>0</v></c><c r=\"B1\"><v>-1.5</v></c><c r=\"C1\"><v>0.1</v></c>" ++
        "<c r=\"D1\"><v>1234567.891</v></c><c r=\"E1\"><v>1000000000000000000000</v></c><c r=\"F1\"><v>0.0000001</v></c>" ++
        "<c r=\"G1\"><v>9007199254740992</v></c><c r=\"H1\"><v>-42</v></c></row>", sheetData(&recorder, "xl/worksheets/sheet1.xml"));
}

test "dates get a date format unless the style names one" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    const sheet = try wb.addSheet("D");
    const day: Date = .{ .year = 1900, .month = 3, .day = 1 };
    try sheet.set(0, 0, .{ .date = day });
    try sheet.setStyled(0, 1, .{ .date = day }, .{ .number_format = .{ .custom = "dd/mm/yyyy" } });
    try sheet.setStyled(0, 2, .{ .date = day }, .{ .bold = true });
    try sheet.setStyled(0, 3, .{ .datetime = .{ .year = 1900, .month = 1, .day = 1, .hour = 18 } }, .{ .number_format = .time });

    var recorder: Recorder = .init();
    defer recorder.deinit();
    try wb.writeToPackager(recorder.packager());
    try testing.expectEqualStrings("<row r=\"1\"><c r=\"A1\" s=\"1\"><v>61</v></c><c r=\"B1\" s=\"2\"><v>61</v></c>" ++
        "<c r=\"C1\" s=\"3\"><v>61</v></c><c r=\"D1\" s=\"4\"><v>1.75</v></c></row>", sheetData(&recorder, "xl/worksheets/sheet1.xml"));
    const styles_xml = recorder.part("xl/styles.xml").?;
    try testing.expect(std.mem.indexOf(u8, styles_xml, "<numFmt numFmtId=\"164\" formatCode=\"dd/mm/yyyy\"/>") != null);
    try testing.expect(std.mem.indexOf(u8, styles_xml, "<xf numFmtId=\"14\" fontId=\"0\"") != null);
    try testing.expect(std.mem.indexOf(u8, styles_xml, "<xf numFmtId=\"164\" fontId=\"0\"") != null);
    try testing.expect(std.mem.indexOf(u8, styles_xml, "<xf numFmtId=\"14\" fontId=\"1\"") != null);
    try testing.expect(std.mem.indexOf(u8, styles_xml, "<xf numFmtId=\"21\" fontId=\"0\"") != null);

    try testing.expectError(error.InvalidDate, sheet.set(1, 0, .{ .date = .{ .year = 1900, .month = 2, .day = 29 } }));
    try testing.expectError(error.InvalidDate, sheet.set(1, 0, .{ .datetime = .{ .year = 2024, .month = 1, .day = 1, .hour = 25 } }));
}

test "Excel's sheet limits" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    const sheet = try wb.addSheet("L");

    try sheet.set(max_rows - 1, max_cols - 1, .int(1));
    try testing.expectError(error.RowOutOfRange, sheet.set(max_rows, 0, .int(1)));
    try testing.expectError(error.ColumnOutOfRange, sheet.set(0, max_cols, .int(1)));
    try testing.expectError(error.ColumnOutOfRange, sheet.setRow(0, max_cols - 1, &.{ .int(1), .int(2) }, .{}));
    try testing.expectError(error.ColumnOutOfRange, sheet.setRow(0, std.math.maxInt(u32), &.{.int(1)}, .{}));
    try sheet.setRow(0, max_cols - 2, &.{ .int(1), .int(2) }, .{});

    try testing.expectError(error.ColumnOutOfRange, sheet.setColumnWidth(max_cols, 10));
    try sheet.setColumnWidth(0, 0);
    try sheet.setColumnWidth(0, max_column_width);
    try testing.expectError(error.InvalidColumnWidth, sheet.setColumnWidth(0, 255.5));
    try testing.expectError(error.InvalidColumnWidth, sheet.setColumnWidth(0, -1));
    try testing.expectError(error.InvalidColumnWidth, sheet.setColumnWidth(0, std.math.nan(f64)));

    try testing.expectError(error.RowOutOfRange, sheet.freeze(max_rows, 0));
    try testing.expectError(error.ColumnOutOfRange, sheet.freeze(0, max_cols));

    try testing.expectError(error.RowOutOfRange, sheet.setAutoFilter(.{ .first_row = 0, .first_col = 0, .last_row = max_rows, .last_col = 0 }));
    try testing.expectError(error.ColumnOutOfRange, sheet.setAutoFilter(.{ .first_row = 0, .first_col = max_cols, .last_row = 0, .last_col = max_cols }));
    try testing.expectError(error.InvalidRange, sheet.setAutoFilter(.{ .first_row = 5, .first_col = 0, .last_row = 4, .last_col = 3 }));
    try testing.expectError(error.InvalidRange, sheet.setAutoFilter(.{ .first_row = 0, .first_col = 3, .last_row = 4, .last_col = 2 }));

    try testing.expectError(error.InvalidNumber, sheet.set(0, 0, .{ .number = std.math.nan(f64) }));
    try testing.expectError(error.InvalidNumber, sheet.set(0, 0, .{ .number = std.math.inf(f64) }));
    try testing.expectError(error.InvalidNumber, sheet.set(0, 0, .{ .number = -std.math.inf(f64) }));
}

test "text limits are counted the way Excel counts" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    const sheet = try wb.addSheet("T");

    const at_limit: [max_text_len]u8 = @splat('a');
    try sheet.set(0, 0, .{ .text = &at_limit });
    const over_limit: [max_text_len + 1]u8 = @splat('a');
    try testing.expectError(error.TextTooLong, sheet.set(0, 0, .{ .text = &over_limit }));

    // "é" is two bytes but one character: 32,767 of them fit.
    var accents: [max_text_len * 2]u8 = undefined;
    for (0..max_text_len) |i| accents[i * 2 ..][0..2].* = "é".*;
    try sheet.set(0, 1, .{ .text = &accents });

    // An emoji is two UTF-16 units: 16,384 of them is one unit too many.
    var emoji: [16_384 * 4]u8 = undefined;
    for (0..16_384) |i| emoji[i * 4 ..][0..4].* = "😀".*;
    try testing.expectError(error.TextTooLong, sheet.set(0, 2, .{ .text = &emoji }));
    try sheet.set(0, 2, .{ .text = emoji[0 .. 16_383 * 4] });

    try testing.expectError(error.InvalidUtf8, sheet.set(0, 3, .{ .text = "caf\xe9" }));
    try testing.expectError(error.InvalidUtf8, sheet.set(0, 3, .{ .text = "\xed\xa0\x80" }));

    try testing.expectError(error.InvalidFormula, sheet.set(0, 4, .{ .formula = "" }));
    try testing.expectError(error.InvalidFormula, sheet.set(0, 4, .{ .formula = "=" }));
    try testing.expectError(error.InvalidFormula, sheet.set(0, 4, .{ .formula = "A1\x00" }));
    try testing.expectError(error.InvalidUtf8, sheet.set(0, 4, .{ .formula = "\xff" }));
    const long_formula: [max_formula_len + 1]u8 = @splat('1');
    try testing.expectError(error.InvalidFormula, sheet.set(0, 4, .{ .formula = &long_formula }));
    try sheet.set(0, 4, .{ .formula = long_formula[0..max_formula_len] });

    try testing.expectError(error.InvalidNumberFormat, sheet.setStyled(0, 5, .int(1), .{ .number_format = .{ .custom = "" } }));
}

test "sheet names follow Excel's rules" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();

    const bad = [_][]const u8{
        "",
        "a/b",
        "a\\b",
        "a?b",
        "a*b",
        "a:b",
        "a[b",
        "a]b",
        "'quoted",
        "quoted'",
        "History",
        "HISTORY",
        "tab\there",
        "nul\x00",
        "12345678901234567890123456789012",
    };
    for (bad) |name| try testing.expectError(error.InvalidSheetName, wb.addSheet(name));
    try testing.expectError(error.InvalidUtf8, wb.addSheet("caf\xe9"));

    _ = try wb.addSheet("1234567890123456789012345678901");
    _ = try wb.addSheet("Março — ações (2026)");
    _ = try wb.addSheet("Resultado");
    try testing.expectError(error.DuplicateSheetName, wb.addSheet("Resultado"));
    try testing.expectError(error.DuplicateSheetName, wb.addSheet("RESULTADO"));
    try testing.expectEqual(@as(usize, 3), wb.sheets.items.len);
}

test "hostile sheet names are escaped wherever they appear" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    const sheet = try wb.addSheet("Tom & \"Jerry\" <1>");
    try sheet.set(0, 0, .int(1));
    try sheet.setAutoFilter(.{ .first_row = 0, .first_col = 0, .last_row = 0, .last_col = 0 });

    var recorder: Recorder = .init();
    defer recorder.deinit();
    try wb.writeToPackager(recorder.packager());
    const workbook_xml = recorder.part("xl/workbook.xml").?;
    try testing.expect(std.mem.indexOf(u8, workbook_xml, "<sheet name=\"Tom &amp; &quot;Jerry&quot; &lt;1&gt;\" sheetId=\"1\"") != null);
    try testing.expect(std.mem.indexOf(u8, workbook_xml, ">'Tom &amp; \"Jerry\" &lt;1&gt;'!$A$1:$A$1</definedName>") != null);
    // The name never reaches a part name.
    try recorder.expectNames(&.{ "[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/worksheets/sheet1.xml", "xl/styles.xml" });
}

test "a workbook needs a sheet" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    var recorder: Recorder = .init();
    defer recorder.deinit();
    try testing.expectError(error.NoSheets, wb.writeToPackager(recorder.packager()));
    try testing.expectError(error.NoSheets, wb.toOwnedSlice(testing.allocator));
}

test "the output is deterministic" {
    const first_wb = try buildSample(testing.allocator);
    defer first_wb.deinit();
    const first = try first_wb.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(first);
    // Writing the same workbook again changes nothing.
    const again = try first_wb.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, first, again);

    // Nor does building it again from scratch.
    const second_wb = try buildSample(testing.allocator);
    defer second_wb.deinit();
    const second = try second_wb.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(second);
    try testing.expectEqualSlices(u8, first, second);

    try testing.expect(std.mem.startsWith(u8, first, "PK\x03\x04"));
}

test "the file is a zip std.zip can read, part for part" {
    const io = testing.io;
    const wb = try buildSample(testing.allocator);
    defer wb.deinit();
    var recorder: Recorder = .init();
    defer recorder.deinit();
    try wb.writeToPackager(recorder.packager());
    const bytes = try wb.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(bytes);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "sample.xlsx", .data = bytes });
    var file = try tmp.dir.openFile(io, "sample.xlsx", .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);

    var it = try std.zip.Iterator.init(&file_reader);
    var index: usize = 0;
    while (try it.next()) |entry| : (index += 1) {
        var name_buffer: [zip.max_part_name_len]u8 = undefined;
        const name = try entry.getFilename(&file_reader, &name_buffer, .{});
        try testing.expectEqualStrings(recorder.names.items[index], name);

        var content: Writer.Allocating = .init(testing.allocator);
        defer content.deinit();
        try entry.extractTo(&file_reader, &content.writer);
        try testing.expectEqualStrings(recorder.contents.items[index], content.written());
        try testing.expectEqual(entry.crc32, std.hash.Crc32.hash(content.written()));
    }
    try testing.expectEqual(recorder.names.items.len, index);
}

test "writeTo reports a failing destination" {
    const wb = try buildSample(testing.allocator);
    defer wb.deinit();
    var small: [64]u8 = undefined;
    var out: Writer = .fixed(&small);
    try testing.expectError(error.WriteFailed, wb.writeTo(&out));
}

fn buildAndWrite(gpa: std.mem.Allocator) !void {
    const wb = try buildSample(gpa);
    defer wb.deinit();
    const extra = try wb.addSheet("Layout");
    try extra.setStyled(0, 0, .{ .text = "Title" }, .{ .font_name = "Times New Roman", .font_size = 12, .h_align = .center, .wrap = true });
    try extra.mergeCells(.{ .first_row = 0, .first_col = 0, .last_row = 0, .last_col = 3 });
    try extra.setRowHeight(0, 30);
    try extra.setRowHeight(4, 18);
    const bytes = try wb.toOwnedSlice(gpa);
    gpa.free(bytes);
}

test "running out of memory at any point leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, buildAndWrite, .{});
}

test "the caller's buffers are not kept" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();

    var name: [5]u8 = "Dados".*;
    const sheet = try wb.addSheet(&name);
    var text: [5]u8 = "texto".*;
    try sheet.set(0, 0, .{ .text = &text });
    var formula: [5]u8 = "A1+B1".*;
    try sheet.set(0, 1, .{ .formula = &formula });
    var code: [4]u8 = "0.00".*;
    try sheet.setStyled(0, 2, .int(1), .{ .number_format = .{ .custom = &code } });
    @memset(&name, 'x');
    @memset(&text, 'x');
    @memset(&formula, 'x');
    @memset(&code, 'x');

    var recorder: Recorder = .init();
    defer recorder.deinit();
    try wb.writeToPackager(recorder.packager());
    try testing.expect(std.mem.indexOf(u8, recorder.part("xl/workbook.xml").?, "name=\"Dados\"") != null);
    try testing.expect(std.mem.indexOf(u8, recorder.part("xl/sharedStrings.xml").?, "<t>texto</t>") != null);
    try testing.expect(std.mem.indexOf(u8, recorder.part("xl/worksheets/sheet1.xml").?, "<f>A1+B1</f>") != null);
    try testing.expect(std.mem.indexOf(u8, recorder.part("xl/styles.xml").?, "formatCode=\"0.00\"") != null);
}

test "merged cells" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    const sheet = try wb.addSheet("M");
    try sheet.set(0, 0, .{ .text = "Title" });
    try sheet.mergeCells(.{ .first_row = 0, .first_col = 0, .last_row = 0, .last_col = 7 });
    try sheet.mergeCells(.{ .first_row = 9, .first_col = 0, .last_row = 12, .last_col = 2 });
    try sheet.setAutoFilter(.{ .first_row = 2, .first_col = 0, .last_row = 5, .last_col = 7 });

    // One cell is not a merge; ranges cannot share a cell; bounds apply.
    try testing.expectError(error.InvalidRange, sheet.mergeCells(.{ .first_row = 3, .first_col = 3, .last_row = 3, .last_col = 3 }));
    try testing.expectError(error.InvalidRange, sheet.mergeCells(.{ .first_row = 4, .first_col = 3, .last_row = 3, .last_col = 3 }));
    try testing.expectError(error.OverlappingMerge, sheet.mergeCells(.{ .first_row = 0, .first_col = 7, .last_row = 1, .last_col = 8 }));
    try testing.expectError(error.OverlappingMerge, sheet.mergeCells(.{ .first_row = 10, .first_col = 1, .last_row = 10, .last_col = 2 }));
    try testing.expectError(error.OverlappingMerge, sheet.mergeCells(.{ .first_row = 8, .first_col = 0, .last_row = 20, .last_col = 9 }));
    try testing.expectError(error.RowOutOfRange, sheet.mergeCells(.{ .first_row = 0, .first_col = 0, .last_row = max_rows, .last_col = 0 }));
    try testing.expectError(error.ColumnOutOfRange, sheet.mergeCells(.{ .first_row = 0, .first_col = 0, .last_row = 0, .last_col = max_cols }));
    // Touching ranges are fine.
    try sheet.mergeCells(.{ .first_row = 1, .first_col = 0, .last_row = 1, .last_col = 7 });

    var recorder: Recorder = .init();
    defer recorder.deinit();
    try wb.writeToPackager(recorder.packager());
    const content = recorder.part("xl/worksheets/sheet1.xml").?;
    // After the filter, in the order they were added.
    try testing.expect(std.mem.endsWith(u8, content, "</sheetData><autoFilter ref=\"A3:H6\"/>" ++
        "<mergeCells count=\"3\"><mergeCell ref=\"A1:H1\"/><mergeCell ref=\"A10:C13\"/><mergeCell ref=\"A2:H2\"/></mergeCells>" ++
        "</worksheet>"));
}

test "row heights, with and without cells in the row" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    const sheet = try wb.addSheet("H");
    try sheet.setRowHeight(0, 33);
    try sheet.set(0, 0, .int(1));
    try sheet.set(1, 0, .int(2));
    try sheet.setRowHeight(3, 20);
    try sheet.setRowHeight(3, 22.5);
    try sheet.set(5, 1, .int(3));
    try sheet.setRowHeight(9, 0);
    try sheet.setRowHeight(7, max_row_height);

    try testing.expectError(error.RowOutOfRange, sheet.setRowHeight(max_rows, 10));
    try testing.expectError(error.InvalidRowHeight, sheet.setRowHeight(0, -1));
    try testing.expectError(error.InvalidRowHeight, sheet.setRowHeight(0, 409.5));
    try testing.expectError(error.InvalidRowHeight, sheet.setRowHeight(0, std.math.nan(f64)));

    var recorder: Recorder = .init();
    defer recorder.deinit();
    try wb.writeToPackager(recorder.packager());
    try testing.expectEqualStrings("<row r=\"1\" ht=\"33\" customHeight=\"1\"><c r=\"A1\"><v>1</v></c></row>" ++
        "<row r=\"2\"><c r=\"A2\"><v>2</v></c></row>" ++
        "<row r=\"4\" ht=\"22.5\" customHeight=\"1\"/>" ++
        "<row r=\"6\"><c r=\"B6\"><v>3</v></c></row>" ++
        "<row r=\"8\" ht=\"409\" customHeight=\"1\"/>" ++
        "<row r=\"10\" ht=\"0\" customHeight=\"1\"/>", sheetData(&recorder, "xl/worksheets/sheet1.xml"));
    // Rows that only have a height are not part of the used range.
    try testing.expect(std.mem.indexOf(u8, recorder.part("xl/worksheets/sheet1.xml").?, "<dimension ref=\"A1:B6\"/>") != null);
}

// The tests below each cover one way real spreadsheets were seen to
// behave (a register of people with phones and document numbers). The
// data here is made up.

/// Writes a one-sheet workbook and returns the recorder holding its parts.
fn record(wb: *Workbook) !Recorder {
    var recorder: Recorder = .init();
    errdefer recorder.deinit();
    try wb.writeToPackager(recorder.packager());
    return recorder;
}

test "real data: text with spaces at the edges and doubled inside is kept as typed" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    const sheet = try wb.addSheet("S");
    try sheet.setRow(0, 0, &.{ .{ .text = "Fulano de Tal " }, .{ .text = " A" }, .{ .text = "Rua  das  Flores" } }, .{});
    var recorder = try record(wb);
    defer recorder.deinit();
    try testing.expect(std.mem.indexOf(u8, recorder.part("xl/sharedStrings.xml").?, "<si><t xml:space=\"preserve\">Fulano de Tal </t></si>" ++
        "<si><t xml:space=\"preserve\"> A</t></si>" ++
        "<si><t>Rua  das  Flores</t></si>") != null);
}

test "real data: several lines in one cell" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    const sheet = try wb.addSheet("S");
    try sheet.setStyled(0, 0, .{ .text = "(11) 91234-5678\n(11) 3456-7890" }, .{ .wrap = true });
    try sheet.set(0, 1, .{ .text = "ends with a break\n" });
    var recorder = try record(wb);
    defer recorder.deinit();
    try testing.expect(std.mem.indexOf(u8, recorder.part("xl/sharedStrings.xml").?, "<si><t>(11) 91234-5678\n(11) 3456-7890</t></si>" ++
        "<si><t xml:space=\"preserve\">ends with a break\n</t></si>") != null);
    try testing.expect(std.mem.indexOf(u8, recorder.part("xl/styles.xml").?, "<alignment wrapText=\"1\"/>") != null);
}

test "real data: document numbers of 11 and 14 digits stored as numbers, shown zero-padded" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    const sheet = try wb.addSheet("S");
    const cpf: Style = .{ .number_format = .{ .custom = "00000000000" } };
    const cnpj: Style = .{ .number_format = .{ .custom = "00000000000000" } };
    try sheet.setStyled(0, 0, .int(12345678901), cpf);
    try sheet.setStyled(1, 0, .int(1234567890), cpf); // shown as 01234567890
    try sheet.setStyled(2, 0, .int(12345678000199), cnpj);
    try sheet.setStyled(3, 0, .int(99999999999999), cnpj);
    var recorder = try record(wb);
    defer recorder.deinit();
    // Every digit survives: 14 digits are well inside a double's 15.
    try testing.expectEqualStrings("<row r=\"1\"><c r=\"A1\" s=\"1\"><v>12345678901</v></c></row>" ++
        "<row r=\"2\"><c r=\"A2\" s=\"1\"><v>1234567890</v></c></row>" ++
        "<row r=\"3\"><c r=\"A3\" s=\"2\"><v>12345678000199</v></c></row>" ++
        "<row r=\"4\"><c r=\"A4\" s=\"2\"><v>99999999999999</v></c></row>", sheetData(&recorder, "xl/worksheets/sheet1.xml"));
    const styles_xml = recorder.part("xl/styles.xml").?;
    try testing.expect(std.mem.indexOf(u8, styles_xml, "<numFmt numFmtId=\"164\" formatCode=\"00000000000\"/>" ++
        "<numFmt numFmtId=\"165\" formatCode=\"00000000000000\"/>") != null);
}

test "real data: digits typed as text stay text, leading zeros included" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    const sheet = try wb.addSheet("S");
    try sheet.setRow(0, 0, &.{ .{ .text = "07" }, .{ .text = "45" }, .{ .text = "123.456.789-09" }, .{ .text = "12.345.678/0001-99" }, .{ .text = "(11) 91234-5678" } }, .{});
    var recorder = try record(wb);
    defer recorder.deinit();
    const data = sheetData(&recorder, "xl/worksheets/sheet1.xml");
    try testing.expectEqual(@as(usize, 5), std.mem.count(u8, data, " t=\"s\">"));
    try testing.expect(std.mem.indexOf(u8, recorder.part("xl/sharedStrings.xml").?, "<si><t>07</t></si><si><t>45</t></si>" ++
        "<si><t>123.456.789-09</t></si><si><t>12.345.678/0001-99</t></si><si><t>(11) 91234-5678</t></si>") != null);
}

test "real data: accents, a non-breaking space and markup characters" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    const sheet = try wb.addSheet("S");
    try sheet.setRow(0, 0, &.{ .{ .text = "FULANO AÇÃO" }, .{ .text = "Lote\u{00A0}12" }, .{ .text = "Exemplo & Teste <matriz>" } }, .{});
    var recorder = try record(wb);
    defer recorder.deinit();
    try testing.expect(std.mem.indexOf(u8, recorder.part("xl/sharedStrings.xml").?, "<si><t>FULANO AÇÃO</t></si>" ++
        "<si><t>Lote\u{00A0}12</t></si>" ++
        "<si><t>Exemplo &amp; Teste &lt;matriz&gt;</t></si>") != null);
}

test "real data: the same text in many cells is stored once" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    const sheet = try wb.addSheet("S");
    for (0..600) |row| {
        try sheet.set(@intCast(row), 0, .{ .text = if (row % 3 == 0) "Inquilino" else "Proprietário" });
    }
    var recorder = try record(wb);
    defer recorder.deinit();
    try testing.expect(std.mem.indexOf(u8, recorder.part("xl/sharedStrings.xml").?, " count=\"600\" uniqueCount=\"2\">" ++
        "<si><t>Inquilino</t></si><si><t>Proprietário</t></si></sst>") != null);
}

test "real data: empty cells in the middle of a row keep their borders" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    const sheet = try wb.addSheet("S");
    const boxed: Style = .{ .border = .thin, .fill = 0xFFFFFF };
    try sheet.setRow(0, 0, &.{ .{ .text = "A" }, .blank, .{ .text = "Nome" }, .blank, .blank, .int(7) }, boxed);
    var recorder = try record(wb);
    defer recorder.deinit();
    try testing.expectEqualStrings("<row r=\"1\"><c r=\"A1\" s=\"1\" t=\"s\"><v>0</v></c><c r=\"B1\" s=\"1\"/>" ++
        "<c r=\"C1\" s=\"1\" t=\"s\"><v>1</v></c><c r=\"D1\" s=\"1\"/><c r=\"E1\" s=\"1\"/><c r=\"F1\" s=\"1\"><v>7</v></c></row>", sheetData(&recorder, "xl/worksheets/sheet1.xml"));
}

test "real data: a title above the header, the filter starting on the third row, rows skipped" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    const sheet = try wb.addSheet("S");
    try sheet.setStyled(1, 0, .{ .text = "Cadastro" }, .{ .bold = true, .h_align = .center });
    try sheet.mergeCells(.{ .first_row = 1, .first_col = 0, .last_row = 1, .last_col = 2 });
    try sheet.setRow(2, 0, &.{ .{ .text = "Quadra" }, .{ .text = "Lote" }, .{ .text = "Nome" } }, .{ .bold = true });
    try sheet.setRow(3, 0, &.{ .{ .text = "A" }, .int(1), .{ .text = "Fulano" } }, .{});
    // Rows 5 to 9 do not exist in the file; a note sits further down.
    try sheet.set(9, 0, .{ .text = "Obs." });
    try sheet.setAutoFilter(.{ .first_row = 2, .first_col = 0, .last_row = 3, .last_col = 2 });
    var recorder = try record(wb);
    defer recorder.deinit();
    const content = recorder.part("xl/worksheets/sheet1.xml").?;
    try testing.expect(std.mem.indexOf(u8, content, "<dimension ref=\"A2:C10\"/>") != null);
    try testing.expect(std.mem.indexOf(u8, content, "<sheetData><row r=\"2\">") != null);
    try testing.expect(std.mem.indexOf(u8, content, "</row><row r=\"4\">") != null);
    try testing.expect(std.mem.indexOf(u8, content, "</row><row r=\"10\">") != null);
    try testing.expect(std.mem.endsWith(u8, content, "<autoFilter ref=\"A3:C4\"/><mergeCells count=\"1\"><mergeCell ref=\"A2:C2\"/></mergeCells></worksheet>"));
    try testing.expect(std.mem.indexOf(u8, recorder.part("xl/workbook.xml").?, "'S'!$A$3:$C$4</definedName>") != null);
}

test "real data: a sheet of many differently styled cells shares a handful of records" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    const sheet = try wb.addSheet("S");
    const base: Style = .{ .font_name = "Times New Roman", .font_size = 10, .border = .thin, .fill = 0xFFFFFF, .v_align = .center };
    var centered = base;
    centered.h_align = .center;
    var wrapped = base;
    wrapped.wrap = true;
    for (0..300) |row| {
        try sheet.setStyled(@intCast(row), 0, .{ .text = "A" }, centered);
        try sheet.setStyled(@intCast(row), 1, .int(row), centered);
        try sheet.setStyled(@intCast(row), 2, .{ .text = "Nome Sobrenome" }, wrapped);
        try sheet.setStyled(@intCast(row), 3, .blank, base);
    }
    var recorder = try record(wb);
    defer recorder.deinit();
    const styles_xml = recorder.part("xl/styles.xml").?;
    try testing.expect(std.mem.indexOf(u8, styles_xml, "<fonts count=\"2\">") != null);
    try testing.expect(std.mem.indexOf(u8, styles_xml, "<fills count=\"3\">") != null);
    try testing.expect(std.mem.indexOf(u8, styles_xml, "<borders count=\"2\">") != null);
    try testing.expect(std.mem.indexOf(u8, styles_xml, "<cellXfs count=\"4\">") != null);
}

test "zoom" {
    const wb = try Workbook.init(testing.allocator);
    defer wb.deinit();
    const zoomed = try wb.addSheet("Z");
    try zoomed.setZoom(80);
    try zoomed.freeze(1, 0);
    const plain = try wb.addSheet("P");
    try plain.setZoom(100);

    try testing.expectError(error.InvalidZoom, zoomed.setZoom(9));
    try testing.expectError(error.InvalidZoom, zoomed.setZoom(401));
    try plain.setZoom(10);
    try plain.setZoom(400);
    try plain.setZoom(100);

    var recorder = try record(wb);
    defer recorder.deinit();
    try testing.expect(std.mem.indexOf(u8, recorder.part("xl/worksheets/sheet1.xml").?, "<sheetView tabSelected=\"1\" zoomScale=\"80\" zoomScaleNormal=\"80\" workbookViewId=\"0\"><pane") != null);
    // 100% is the default and is not written.
    try testing.expect(std.mem.indexOf(u8, recorder.part("xl/worksheets/sheet2.xml").?, "<sheetView workbookViewId=\"0\"/>") != null);
}
