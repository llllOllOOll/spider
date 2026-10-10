//! Public API — pure-Zig writing and reading of Excel .xlsx files. No
//! C, no dependency besides `std`, no global state, no temporary files.
//!
//! Writing: build a `Workbook`, add sheets, set cells, then get the
//! file as bytes or write it to any `std.Io.Writer`:
//!
//!     const wb = try xlsx.Workbook.init(allocator);
//!     defer wb.deinit();
//!     const sheet = try wb.addSheet("Results");
//!     try sheet.setRow(0, 0, &.{ .{ .text = "Option" }, .{ .text = "Votes" } }, .{ .bold = true });
//!     try sheet.setRow(1, 0, &.{ .{ .text = "Yes" }, .int(12) }, .{});
//!     const bytes = try wb.toOwnedSlice(allocator);
//!
//! Reading: open the bytes of a file with limits and iterate the rows
//! of a sheet, typed, in bounded memory:
//!
//!     const book = try xlsx.Reader.open(allocator, bytes, .{});
//!     defer book.deinit();
//!     const rows = try book.rows(0, .{});
//!     defer rows.deinit();
//!     while (try rows.next()) |row| { … }
//!
//! Written: several sheets; text, numbers, booleans, dates and
//! formulas; column widths and row heights; fonts, background colour,
//! borders, alignment, wrapped text and number formats; merged cells;
//! links; hidden rows and columns; frozen panes, zoom and a filter per
//! sheet; page setup, print area, page breaks, header and footer;
//! protection. Read: sheets, rows and typed cells with their number
//! format, cached formula results, merged ranges. Not done: streamed
//! writing, compression, charts and images, .xls (see README.md).

const std = @import("std");

// internal: the zip writer; reexported for the tests.
pub const zip = @import("zip.zig");
// internal: XML output helpers; reexported for the tests.
pub const xml = @import("xml.zig");
// internal: cell addresses; reexported for the tests.
pub const cell_ref = @import("cell_ref.zig");
// internal: date conversion; reexported for the tests.
pub const date = @import("date.zig");
// internal: the styles table; reexported for the tests.
pub const styles = @import("styles.zig");
// internal: the shared strings table; reexported for the tests.
pub const shared_strings = @import("shared_strings.zig");
// internal: the writer; reexported for the tests.
pub const workbook = @import("workbook.zig");
// internal: the zip reader; reexported for the tests.
pub const zip_reader = @import("zip_reader.zig");
// internal: the XML reader; reexported for the tests.
pub const xml_reader = @import("xml_reader.zig");
// internal: the reader; reexported for the tests.
pub const reader = @import("reader.zig");

/// A workbook being built: add sheets, then `toOwnedSlice` or `writeTo`.
pub const Workbook = workbook.Workbook;
/// One sheet of a `Workbook`, where cells are set. Rows and columns are zero-based.
pub const Sheet = workbook.Sheet;
/// What a written cell holds: text, a number, a boolean, a date, a formula or nothing.
pub const Value = workbook.Value;
/// Everything building or writing a workbook can fail with.
pub const Error = workbook.Error;

/// The formatting of one cell; `.{}` is a plain cell.
pub const Style = styles.Style;
/// The kinds of line around a cell, for `Style`.
pub const Border = styles.Border;
/// How a cell's background is painted, for `Style`.
pub const FillPattern = styles.FillPattern;
/// How a number or date is shown, for `Style`.
pub const NumberFormat = styles.NumberFormat;
/// Left, centre, right placement of a cell's content, for `Style`.
pub const HorizontalAlignment = styles.HorizontalAlignment;
/// Top, middle, bottom placement of a cell's content, for `Style`.
pub const VerticalAlignment = styles.VerticalAlignment;

/// A calendar date, for a cell value.
pub const Date = date.Date;
/// A calendar date with a time of day, for a cell value.
pub const DateTime = date.DateTime;
/// A rectangle of cells, both corners included (merges, print area, filter).
pub const Range = cell_ref.Range;

/// How a sheet is printed: paper, orientation, margins, scale.
pub const PageSetup = workbook.PageSetup;
/// Paper sizes for `PageSetup`.
pub const Paper = workbook.Paper;
/// Portrait or landscape, for `PageSetup`.
pub const Orientation = workbook.Orientation;
/// Page margins in inches, for `PageSetup`.
pub const Margins = workbook.Margins;
/// Text printed at the top and bottom of every page.
pub const HeaderFooter = workbook.HeaderFooter;
/// Options of `Workbook.protect` and `Sheet.protect`.
pub const Protection = workbook.Protection;
/// Centimetres to inches, for `Margins`.
pub const cm = workbook.cm;
/// The usual look of a link (blue, underlined), to pass with a linked cell's value.
pub const link_style = workbook.link_style;

// Reading. `Reader.open(gpa, bytes, .{})`, then `reader.rows(sheet, .{})`.
/// An open .xlsx file to read: `Reader.open(gpa, bytes, .{})`, then `reader.rows(sheet, .{})`.
pub const Reader = reader.Reader;
/// The rows of one sheet, read one at a time with `next`.
pub const Rows = reader.Rows;
/// How much a file may ask of the server before it is refused; `.{}` suits uploads.
pub const ReadLimits = reader.Limits;
/// Options of `Reader.rows`.
pub const ReadOptions = reader.Options;
/// Everything opening or reading a file can fail with.
pub const ReadError = reader.Error;
/// Where in the file the last read error happened.
pub const ReadDiagnostic = reader.Diagnostic;
/// One row read from a sheet, valid until the next call to `Rows.next`.
pub const ReadRow = reader.Row;
/// One cell of a `ReadRow`: column, value, number format, formula.
pub const ReadCell = reader.Cell;
/// What a read cell holds: text, a number, a boolean, a date, a time, an error or nothing.
pub const ReadValue = reader.Value;
/// The name and visibility of one sheet, from `Reader.sheets`.
pub const SheetInfo = reader.SheetInfo;
/// The time of day of a read cell that holds no date.
pub const TimeOfDay = date.TimeOfDay;
/// Which limit a file went over: the type of `ReadDiagnostic.limit`.
pub const ReadLimitKind = reader.LimitKind;
/// Which part of the file a read error is about: the type of `ReadDiagnostic.part`.
pub const ReadPart = reader.Part;
/// Whether a sheet is shown, hidden, or hidden from the menu too: the type of `SheetInfo.visibility`.
pub const SheetVisibility = reader.Visibility;
/// Which day serial number 0 stands for in a workbook: the 1900 system, or the 1904 one of old Mac files.
pub const DateSystem = date.DateSystem;

/// The container seam: implement `Packager` to replace the zip writer.
pub const Packager = zip.Packager;
/// The zip writer the module uses: every part stored uncompressed.
pub const StoreZip = zip.StoreZip;

/// The MIME type of a .xlsx file, for a `Content-Type` header.
pub const content_type = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

/// Excel's limits, enforced by `Sheet` and `Workbook`: rows per sheet.
pub const max_rows = workbook.max_rows;
/// Columns per sheet.
pub const max_cols = workbook.max_cols;
/// Characters per cell.
pub const max_text_len = workbook.max_text_len;
/// Characters per formula.
pub const max_formula_len = workbook.max_formula_len;
/// Characters per sheet name.
pub const max_sheet_name_len = workbook.max_sheet_name_len;
/// Widest column, in characters of the default font.
pub const max_column_width = workbook.max_column_width;
/// Tallest row, in points.
pub const max_row_height = workbook.max_row_height;
/// Longest link target, in bytes.
pub const max_link_len = workbook.max_link_len;
/// Links per sheet.
pub const max_links_per_sheet = workbook.max_links_per_sheet;

test {
    _ = zip;
    _ = xml;
    _ = cell_ref;
    _ = date;
    _ = styles;
    _ = shared_strings;
    _ = workbook;
    _ = zip_reader;
    _ = xml_reader;
    _ = reader;
}

test "the types of the fields a caller reads have a name at the root" {
    // ReadDiagnostic.limit, ReadDiagnostic.part, SheetInfo.visibility and
    // the date system of a workbook: a caller that switches on them, or
    // stores them, has to be able to write their type.
    const diagnostic: ReadDiagnostic = .{};
    const limit: ?ReadLimitKind = diagnostic.limit;
    const part: ReadPart = diagnostic.part;
    try std.testing.expect(limit == null);
    try std.testing.expectEqual(ReadPart.none, part);
    try std.testing.expect(SheetVisibility == @FieldType(SheetInfo, "visibility"));
    try std.testing.expect(@typeInfo(DateSystem) == .@"enum");
}
