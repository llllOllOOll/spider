//! Public API — a pure-Zig writer for Excel .xlsx files. No C, no
//! dependency besides `std`, no global state, no temporary files.
//!
//! Build a `Workbook`, add sheets, set cells, then get the file as
//! bytes or write it to any `std.Io.Writer`:
//!
//!     const wb = try xlsx.Workbook.init(allocator);
//!     defer wb.deinit();
//!     const sheet = try wb.addSheet("Results");
//!     try sheet.setRow(0, 0, &.{ .{ .text = "Option" }, .{ .text = "Votes" } }, .{ .bold = true });
//!     try sheet.setRow(1, 0, &.{ .{ .text = "Yes" }, .int(12) }, .{});
//!     const bytes = try wb.toOwnedSlice(allocator);
//!
//! Scope: several sheets; text, numbers, booleans, dates and formulas;
//! column widths; bold, background colour, borders and number formats;
//! frozen panes; a filter per sheet. Reading files, streamed writing,
//! compression, charts and images are not implemented (see README.md).

const std = @import("std");

pub const zip = @import("zip.zig");
pub const xml = @import("xml.zig");
pub const cell_ref = @import("cell_ref.zig");
pub const date = @import("date.zig");
pub const styles = @import("styles.zig");
pub const shared_strings = @import("shared_strings.zig");
pub const workbook = @import("workbook.zig");

pub const Workbook = workbook.Workbook;
pub const Sheet = workbook.Sheet;
pub const Value = workbook.Value;
pub const Error = workbook.Error;

pub const Style = styles.Style;
pub const Border = styles.Border;
pub const NumberFormat = styles.NumberFormat;
pub const HorizontalAlignment = styles.HorizontalAlignment;
pub const VerticalAlignment = styles.VerticalAlignment;

pub const Date = date.Date;
pub const DateTime = date.DateTime;
pub const Range = cell_ref.Range;

/// The container seam: implement `Packager` to replace the zip writer.
pub const Packager = zip.Packager;
pub const StoreZip = zip.StoreZip;

/// The MIME type of a .xlsx file, for a `Content-Type` header.
pub const content_type = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

/// Excel's limits, enforced by `Sheet` and `Workbook`.
pub const max_rows = workbook.max_rows;
pub const max_cols = workbook.max_cols;
pub const max_text_len = workbook.max_text_len;
pub const max_formula_len = workbook.max_formula_len;
pub const max_sheet_name_len = workbook.max_sheet_name_len;
pub const max_column_width = workbook.max_column_width;
pub const max_row_height = workbook.max_row_height;

test {
    _ = zip;
    _ = xml;
    _ = cell_ref;
    _ = date;
    _ = styles;
    _ = shared_strings;
    _ = workbook;
}
