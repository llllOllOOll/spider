//! Helper executable for `zig build sample-files`: writes workbooks for
//! checking by hand in Excel, Google Sheets and Numbers — the programs
//! the automated tests cannot drive.
//!
//!     sample_files <output-dir>
//!
//! Three files, always the same bytes:
//!
//! - `1-a-bit-of-everything.xlsx`: every feature of the module at least once.
//! - `2-poll.xlsx`: what a poll export looks like, about 200 rows.
//! - `3-limits.xlsx`: a cell at the text limit, a sheet name at the
//!   name limit, a value in the very last cell of a sheet.
//!
//! All names and data are made up. Some cell text has accented words
//! on purpose: accents are part of what is being checked.

const std = @import("std");
const xlsx = @import("xlsx");

const header: xlsx.Style = .{ .bold = true, .fill = 0xDCE6F1, .border = .thin };
const br_date: xlsx.Style = .{ .number_format = .{ .custom = "dd/mm/yyyy" } };
const br_datetime: xlsx.Style = .{ .number_format = .{ .custom = "dd/mm/yyyy hh:mm" } };

fn text(value: []const u8) xlsx.Value {
    return .{ .text = value };
}

fn everything(gpa: std.mem.Allocator) !*xlsx.Workbook {
    const wb = try xlsx.Workbook.init(gpa);
    errdefer wb.deinit();

    const overview = try wb.addSheet("Overview");
    try overview.setColumnWidth(0, 34);
    try overview.setColumnWidth(1, 44);
    try overview.setColumnWidth(2, 50);
    try overview.setRow(0, 0, &.{ text("What it is"), text("Value"), text("What you should see") }, header);
    const rows = [_][3]xlsx.Value{
        .{ text("Text with accents"), text("Café, naïve, résumé, façade, jalapeño"), text("The accents show correctly") },
        .{ text("Text with emoji"), text("Approved ✅ 🎉 😀"), text("The three emoji show") },
        .{ text("Text starting with ="), text("=SUM(1,2)"), text("The text =SUM(1,2) shows, not the number 3") },
        .{ text("Text starting with +"), text("+1 555 0100 2000"), text("The whole phone number shows, as text") },
        .{ text("Text with quotes and signs"), text("He said \"hi\" & left <early>"), text("Quotes, & and < > show as they are") },
        .{ text("Text on two lines"), text("first line\nsecond line"), text("Two lines in the same cell (the row may need to be taller)") },
        .{ text("Number that is text"), text("00123"), text("00123 shows, with the zeros, aligned left") },
        .{ text("True"), .{ .boolean = true }, text("TRUE (or the word for it in your language)") },
        .{ text("False"), .{ .boolean = false }, text("FALSE (or the word for it in your language)") },
    };
    for (rows, 1..) |row, index| try overview.setRow(@intCast(index), 0, &row, .{});
    try overview.freeze(1, 0);
    try overview.setAutoFilter(.{ .first_row = 0, .first_col = 0, .last_row = rows.len, .last_col = 2 });

    const numbers = try wb.addSheet("Numbers and dates");
    try numbers.setColumnWidth(0, 34);
    try numbers.setColumnWidth(1, 22);
    try numbers.setColumnWidth(2, 50);
    try numbers.setRow(0, 0, &.{ text("What it is"), text("Value"), text("What you should see") }, header);
    try numbers.freeze(1, 1);

    try numbers.set(1, 0, text("Integer"));
    try numbers.set(1, 1, .int(42));
    try numbers.set(1, 2, text("42"));
    try numbers.set(2, 0, text("Decimal"));
    try numbers.set(2, 1, .{ .number = 3.14159 });
    try numbers.set(2, 2, text("3.14159 (3,14159 in some languages)"));
    try numbers.set(3, 0, text("Two decimals"));
    try numbers.setStyled(3, 1, .{ .number = 1234.5 }, .{ .number_format = .decimal });
    try numbers.set(3, 2, text("1234.50"));
    try numbers.set(4, 0, text("Thousands and two decimals"));
    try numbers.setStyled(4, 1, .{ .number = 1234567.891 }, .{ .number_format = .thousands_decimal });
    try numbers.set(4, 2, text("1,234,567.89 (or 1.234.567,89)"));
    try numbers.set(5, 0, text("Negative"));
    try numbers.setStyled(5, 1, .{ .number = -1250.5 }, .{ .number_format = .thousands_decimal });
    try numbers.set(5, 2, text("-1,250.50 (or -1.250,50)"));
    try numbers.set(6, 0, text("Percent"));
    try numbers.setStyled(6, 1, .{ .number = 0.375 }, .{ .number_format = .percent_decimal });
    try numbers.set(6, 2, text("37.50%"));
    try numbers.set(7, 0, text("Whole percent"));
    try numbers.setStyled(7, 1, .{ .number = 0.75 }, .{ .number_format = .percent });
    try numbers.set(7, 2, text("75%"));
    try numbers.set(8, 0, text("Date (the program's format)"));
    try numbers.set(8, 1, .{ .date = .{ .year = 2026, .month = 10, .day = 7 } });
    try numbers.set(8, 2, text("October 7, 2026, in your program's date format"));
    try numbers.set(9, 0, text("Date (dd/mm/yyyy)"));
    try numbers.setStyled(9, 1, .{ .date = .{ .year = 2026, .month = 10, .day = 7 } }, br_date);
    try numbers.set(9, 2, text("07/10/2026"));
    try numbers.set(10, 0, text("Date and time (the program's format)"));
    try numbers.set(10, 1, .{ .datetime = .{ .year = 2026, .month = 10, .day = 7, .hour = 14, .minute = 30 } });
    try numbers.set(10, 2, text("October 7, 2026, 14:30"));
    try numbers.set(11, 0, text("Date and time (dd/mm/yyyy hh:mm)"));
    try numbers.setStyled(11, 1, .{ .datetime = .{ .year = 2026, .month = 10, .day = 7, .hour = 14, .minute = 30 } }, br_datetime);
    try numbers.set(11, 2, text("07/10/2026 14:30"));
    try numbers.set(12, 0, text("Time"));
    try numbers.setStyled(12, 1, .{ .datetime = .{ .year = 1900, .month = 1, .day = 1, .hour = 9, .minute = 5, .second = 30 } }, .{ .number_format = .time });
    try numbers.set(12, 2, text("9:05:30"));
    try numbers.set(13, 0, text("Formula: sum of B2 and B3"));
    try numbers.set(13, 1, .{ .formula = "SUM(B2:B3)" });
    try numbers.set(13, 2, text("45.14159"));
    try numbers.set(14, 0, text("Formula: condition"));
    try numbers.set(14, 1, .{ .formula = "IF(B2>40,\"higher\",\"lower\")" });
    try numbers.set(14, 2, text("higher"));

    try numbers.set(16, 0, text("Yellow background"));
    try numbers.setStyled(16, 1, text("yellow"), .{ .fill = 0xFFFF00 });
    try numbers.set(17, 0, text("Green background, bold"));
    try numbers.setStyled(17, 1, text("green"), .{ .fill = 0xC6EFCE, .bold = true });
    try numbers.set(19, 0, text("Thin border"));
    try numbers.setStyled(19, 1, text("thin"), .{ .border = .thin });
    try numbers.set(21, 0, text("Medium border"));
    try numbers.setStyled(21, 1, text("medium"), .{ .border = .medium });
    try numbers.set(23, 0, text("Thick border"));
    try numbers.setStyled(23, 1, text("thick"), .{ .border = .thick });

    const layout = try wb.addSheet("Appearance");
    const layout_widths = [_]f64{ 12, 12, 40, 26 };
    for (layout_widths, 0..) |width, col| try layout.setColumnWidth(@intCast(col), width);
    const boxed: xlsx.Style = .{ .font_name = "Times New Roman", .font_size = 10, .border = .thin, .v_align = .center };
    var title = boxed;
    title.bold = true;
    title.font_size = 14;
    title.h_align = .center;
    try layout.setRow(0, 0, &.{ text("SAMPLE REGISTER — MERGED AND CENTERED TITLE"), .blank, .blank, .blank }, title);
    try layout.mergeCells(.{ .first_row = 0, .first_col = 0, .last_row = 0, .last_col = 3 });
    try layout.setRowHeight(0, 30);
    var column_title = boxed;
    column_title.bold = true;
    column_title.fill = 0xD7E4BD;
    column_title.h_align = .center;
    try layout.setRow(1, 0, &.{ text("Block"), text("Lot"), text("Name"), text("Phone") }, column_title);
    var centered = boxed;
    centered.h_align = .center;
    var wrapped = boxed;
    wrapped.wrap = true;
    var right = boxed;
    right.h_align = .right;
    try layout.setStyled(2, 0, text("A"), centered);
    try layout.setStyled(2, 1, .int(12), centered);
    try layout.setStyled(2, 2, text("Long text that does not fit the width of the column, so it wraps over several lines inside the cell"), wrapped);
    try layout.setStyled(2, 3, text("(555) 012-3456\n(555) 098-7654"), wrapped);
    try layout.setRowHeight(2, 52);
    try layout.setStyled(3, 0, text("B"), centered);
    try layout.setStyled(3, 1, .int(7), centered);
    try layout.setStyled(3, 2, text("Aligned right"), right);
    try layout.setStyled(3, 3, .blank, boxed);
    try layout.setStyled(5, 2, text("Italic"), .{ .italic = true });
    try layout.setStyled(6, 2, text("Underlined and blue"), .{ .underline = true, .font_color = 0x0000FF });
    try layout.setStyled(7, 2, text("Red, bold, size 16"), .{ .bold = true, .font_color = 0xC00000, .font_size = 16 });
    try layout.setStyled(8, 2, text("Courier New font"), .{ .font_name = "Courier New" });
    try layout.setStyled(9, 2, text("At the top of the cell"), .{ .v_align = .top, .border = .thin });
    try layout.setRowHeight(9, 40);
    try layout.setStyled(11, 2, text("Open the example site"), xlsx.link_style);
    try layout.setLink(11, 2, "https://example.com/");
    try layout.setStyled(12, 2, text("contact@example.com"), xlsx.link_style);
    try layout.setLink(12, 2, "mailto:contact@example.com");
    try layout.setStyled(14, 2, text("Text that shrinks to fit the width of the column, without wrapping"), .{ .shrink = true, .border = .thin });
    try layout.setStyled(16, 2, text("Only the bottom line"), .{ .border_bottom = .medium });
    try layout.setStyled(18, 2, text("Without the top line"), .{ .border = .thin, .border_top = .none });
    try layout.setStyled(20, 2, text("Double border below, in red"), .{ .border_bottom = .double, .border_color = 0xC00000 });
    try layout.setStyled(22, 2, text("Dotted border"), .{ .border = .dotted });
    try layout.setStyled(24, 2, text("Dotted gray background"), .{ .fill_pattern = .light_gray });
    try layout.set(26, 2, text("Column F is hidden, and so is row 29"));
    try layout.set(26, 5, text("hidden column"));
    try layout.hideColumn(5);
    try layout.set(28, 2, text("hidden row"));
    try layout.hideRow(28);
    try layout.setHeaderFooter(.{ .header = "&CTest sheet", .footer = "&LAppearance&RPage &P of &N" });
    try layout.setZoom(120);
    try layout.setPageSetup(.{ .paper = .a4, .orientation = .landscape, .margins = .{ .left = xlsx.cm(1.5), .right = xlsx.cm(1.5) } });

    // Exactly 31 characters, with accents and a dash.
    const long_name = try wb.addSheet("Café occupancy report — block A");
    try long_name.setColumnWidth(0, 60);
    try long_name.set(0, 0, text("The name of this sheet has 31 characters, the most allowed."));
    try long_name.set(1, 0, text("It must show whole on the tab: Café occupancy report — block A"));
    return wb;
}

const options = [_][]const u8{
    "Approve the lobby renovation",
    "Approve with budget changes",
    "Postpone to the next meeting",
    "Do not approve",
};
const first_names = [_][]const u8{ "Alex", "Sam", "Jordan", "Taylor", "Morgan", "Casey", "Riley", "Jamie", "Avery", "Quinn", "Robin", "Drew", "Chris", "Pat", "Jesse", "Logan" };
const last_names = [_][]const u8{ "Doe", "Example", "Test", "Sample", "Fictional", "Madeup", "Placeholder", "Generic", "Mock", "Anyone", "Demo" };
const roles = [_][]const u8{ "Owner", "Owner", "Owner", "Proxy", "Resident" };
const reasons = [_][]const u8{
    "",
    "",
    "",
    "The current lobby cannot hold the deliveries.",
    "I would rather wait for the year's accounts to close.",
    "The budget presented is above what was agreed.",
    "I agree, as long as the work takes no more than two months.",
};
const vote_count = 200;

/// Which option a made-up voter picks: spread unevenly, so the result
/// sheet has something to show.
fn choice(voter: usize) usize {
    return switch ((voter * 7 + voter / 3) % 10) {
        0...4 => 0,
        5...6 => 1,
        7...8 => 2,
        else => 3,
    };
}

fn poll(gpa: std.mem.Allocator) !*xlsx.Workbook {
    const wb = try xlsx.Workbook.init(gpa);
    errdefer wb.deinit();

    var counts: [options.len]u32 = @splat(0);
    for (0..vote_count) |voter| counts[choice(voter)] += 1;

    const result = try wb.addSheet("Result");
    try result.setColumnWidth(0, 40);
    try result.setColumnWidth(1, 12);
    try result.setColumnWidth(2, 14);
    try result.setRow(0, 0, &.{ text("Option"), text("Units"), text("Percent") }, header);
    for (options, counts, 1..) |option, count, row| {
        try result.set(@intCast(row), 0, text(option));
        try result.set(@intCast(row), 1, .int(count));
        try result.setStyled(@intCast(row), 2, .{ .number = @as(f64, @floatFromInt(count)) / vote_count }, .{ .number_format = .percent_decimal });
    }
    const total_row = options.len + 1;
    const total: xlsx.Style = .{ .bold = true, .border = .thin };
    try result.setStyled(total_row, 0, text("Total"), total);
    try result.setStyled(total_row, 1, .{ .formula = "SUM(B2:B5)" }, total);
    try result.setStyled(total_row, 2, .{ .formula = "SUM(C2:C5)" }, .{ .bold = true, .border = .thin, .number_format = .percent_decimal });
    try result.freeze(1, 0);
    try result.setAutoFilter(.{ .first_row = 0, .first_col = 0, .last_row = options.len, .last_col = 2 });

    const votes = try wb.addSheet("Votes");
    const widths = [_]f64{ 18, 28, 16, 38, 18, 52 };
    for (widths, 0..) |width, col| try votes.setColumnWidth(@intCast(col), width);
    try votes.setRow(0, 0, &.{
        text("Unit"),
        text("Who voted"),
        text("Relation"),
        text("Options chosen"),
        text("Date and time"),
        text("Reason"),
    }, header);

    // Voting opens on 2026-09-21 09:00 (UTC) and votes trickle in.
    const opened_at: i64 = 1_789_981_200;
    for (0..vote_count) |voter| {
        const row: u32 = @intCast(voter + 1);
        var unit_buffer: [32]u8 = undefined;
        const unit = try std.fmt.bufPrint(&unit_buffer, "Block {c} - {d}", .{
            @as(u8, 'A' + @as(u8, @intCast(voter / 50))),
            (voter % 50 / 5 + 1) * 100 + voter % 5 + 1,
        });
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "{s} {s}", .{
            first_names[(voter * 5 + 3) % first_names.len],
            last_names[(voter * 3 + voter / 7) % last_names.len],
        });
        try votes.set(row, 0, text(unit));
        try votes.set(row, 1, text(name));
        try votes.set(row, 2, text(roles[(voter * 3 + 1) % roles.len]));
        try votes.set(row, 3, text(options[choice(voter)]));
        try votes.setStyled(row, 4, .{ .datetime = try .fromUnix(opened_at + @as(i64, @intCast(voter)) * 2711) }, br_datetime);
        try votes.set(row, 5, text(reasons[(voter * 4 + voter / 5) % reasons.len]));
    }
    try votes.freeze(1, 1);
    try votes.setAutoFilter(.{ .first_row = 0, .first_col = 0, .last_row = vote_count, .last_col = 5 });
    // Printed on A4 lying down, with the header on every page.
    // One page wide, as many pages down as it takes, numbered.
    try votes.setPageSetup(.{ .paper = .a4, .orientation = .landscape, .fit_to_width = 1, .fit_to_height = 0 });
    try votes.setPrintTitleRows(0, 0);
    try votes.setHeaderFooter(.{ .footer = "&CPage &P of &N" });
    // The result cannot be edited by accident (no password).
    try result.protect(.{});
    return wb;
}

fn limits(gpa: std.mem.Allocator) !*xlsx.Workbook {
    const wb = try xlsx.Workbook.init(gpa);
    errdefer wb.deinit();

    // Exactly 31 characters.
    const sheet = try wb.addSheet("Sheet name with 31 characters!!");
    try sheet.setColumnWidth(0, 60);
    try sheet.set(0, 0, text("Cell A3 holds a text of 32,767 characters, the most a cell takes."));
    try sheet.set(1, 0, text("It starts with START and ends with END. Check it with the formula =LEN(A3)."));
    const long_text = try gpa.alloc(u8, xlsx.max_text_len);
    defer gpa.free(long_text);
    for (long_text, 0..) |*c, i| c.* = '0' + @as(u8, @intCast(i % 10));
    @memcpy(long_text[0..5], "START");
    @memcpy(long_text[long_text.len - 3 ..], "END");
    try sheet.set(2, 0, text(long_text));

    const corner = try wb.addSheet("Last corner");
    try corner.setColumnWidth(0, 60);
    try corner.set(0, 0, text("The last possible cell (XFD1048576) holds the text \"corner\"."));
    try corner.set(1, 0, text("Press Ctrl+End to go there."));
    try corner.set(xlsx.max_rows - 1, xlsx.max_cols - 1, text("corner"));
    return wb;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = arg_it.next(); // executable name
    const out_path = arg_it.next() orelse return error.MissingOutputDirectory;

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, out_path);
    var out_dir = try cwd.openDir(io, out_path, .{});
    defer out_dir.close(io);

    const Sample = struct { name: []const u8, build: *const fn (std.mem.Allocator) anyerror!*xlsx.Workbook };
    for ([_]Sample{
        .{ .name = "1-a-bit-of-everything.xlsx", .build = everything },
        .{ .name = "2-poll.xlsx", .build = poll },
        .{ .name = "3-limits.xlsx", .build = limits },
    }) |sample| {
        const wb = try sample.build(gpa);
        defer wb.deinit();
        var file = try out_dir.createFile(io, sample.name, .{});
        defer file.close(io);
        var buffer: [8192]u8 = undefined;
        var file_writer = file.writer(io, &buffer);
        try wb.writeTo(&file_writer.interface);
        try file_writer.interface.flush();
    }
}
