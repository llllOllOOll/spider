//! Helper executable for `zig build test-libreoffice`: proves that a
//! real, independent spreadsheet program opens what this module writes
//! and sees the same cells.
//!
//!     libreoffice_check <work-dir>
//!
//! Writes a sample workbook into the directory, has headless
//! LibreOffice (`soffice`) convert it to one CSV per sheet — "as
//! shown", so number formats, dates and the formula result are part of
//! the comparison — and compares each CSV with what is expected.
//!
//! Then the other way round, for the reader: it reads the sample it
//! just wrote, and it reads a workbook LibreOffice itself makes from a
//! CSV file — a file by another producer, compressed, with its own
//! way of writing XML.
//!
//! LibreOffice runs with a private profile inside the work directory,
//! so the check neither depends on nor touches the user's settings.
//! The sample avoids anything that depends on the reader's locale:
//! dates use explicit format codes instead of the built-in date format.

const std = @import("std");
const xlsx = @import("xlsx");

const results_csv =
    \\Opção,Votos,%,Data
    \\Sim,12,75%,2026-10-07
    \\"Não, talvez",4,25%,2026-10-07 13:01:01
    \\Total,16,TRUE,=1+1
    \\"He said ""hi""",1234.50,  padded  ,a<b&c>d
    \\1900-03-01,-0.5,+55 11 99999-0000,@handle
    \\
;

const votes_csv =
    \\Unidade,Opção
    \\101,Sim
    \\Bloco A — 12,Não
    \\
;

/// What the reader must give for the "Results" sheet of the sample.
const results_read =
    \\0: 'Opção' 'Votos' '%' 'Data'
    \\1: 'Sim' 12 0.75 2026-10-07T00:00:00
    \\2: 'Não, talvez' 4 0.25 2026-10-07T13:01:01
    \\3: 'Total' =SUM(B2:B3) true '=1+1'
    \\4: 'He said "hi"' 1234.5 '  padded  ' 'a<b&c>d'
    \\5: 1900-03-01T00:00:00 -0.5 '+55 11 99999-0000' '@handle'
    \\
;

/// A table as an application would receive it from a person.
const import_csv =
    \\Nome,Quantidade,Preço,Data,Ativo
    \\"Tal, Fulano",12,3.5,2026-10-07,TRUE
    \\Sicrano,0,-1250.75,2024-02-29,FALSE
    \\"Linha 1
    \\Linha 2",7,0.125,1999-12-31,TRUE
    \\
;

/// What the reader must give for the workbook LibreOffice makes of it.
const import_read =
    \\0: 'Nome' 'Quantidade' 'Preço' 'Data' 'Ativo'
    \\1: 'Tal, Fulano' 12 3.5 2026-10-07T00:00:00 true
    \\2: 'Sicrano' 0 -1250.75 2024-02-29T00:00:00 false
    \\3: 'Linha 1
    \\Linha 2' 7 0.125 1999-12-31T00:00:00 true
    \\
;

/// Reads the first sheet of a workbook file into one line per row.
fn readBack(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) ![]u8 {
    const bytes = try dir.readFileAlloc(io, name, gpa, .limited(16 << 20));
    defer gpa.free(bytes);
    const book = try xlsx.Reader.open(gpa, bytes, .{});
    defer book.deinit();
    const rows = try book.rows(0, .{ .formulas = true });
    defer rows.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    while (try rows.next()) |row| {
        try w.print("{d}:", .{row.number});
        for (row.cells) |cell| {
            try w.writeByte(' ');
            if (cell.formula) |formula| {
                try w.print("={s}", .{formula});
                continue;
            }
            switch (cell.value) {
                .empty => try w.writeByte('_'),
                .text => |t| try w.print("'{s}'", .{t}),
                .number => |n| try w.print("{d}", .{n}),
                .boolean => |b| try w.print("{}", .{b}),
                .date => |d| try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ d.year, d.month, d.day, d.hour, d.minute, d.second }),
                .time => |t| try w.print("T{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second }),
                .err => |e| try w.print("!{s}", .{e}),
            }
        }
        try w.writeByte('\n');
    }
    return out.toOwnedSlice();
}

fn buildSample(gpa: std.mem.Allocator) !*xlsx.Workbook {
    const wb = try xlsx.Workbook.init(gpa);
    errdefer wb.deinit();

    const header: xlsx.Style = .{ .bold = true, .fill = 0xDDEEFF, .border = .thin };
    const iso_date: xlsx.Style = .{ .number_format = .{ .custom = "yyyy-mm-dd" } };
    const iso_datetime: xlsx.Style = .{ .number_format = .{ .custom = "yyyy-mm-dd hh:mm:ss" } };

    const results = try wb.addSheet("Results");
    try results.setColumnWidth(0, 30);
    try results.setColumnWidth(3, 22);
    try results.setRow(0, 0, &.{ .{ .text = "Opção" }, .{ .text = "Votos" }, .{ .text = "%" }, .{ .text = "Data" } }, header);
    try results.set(1, 0, .{ .text = "Sim" });
    try results.set(1, 1, .int(12));
    try results.setStyled(1, 2, .{ .number = 0.75 }, .{ .number_format = .percent });
    try results.setStyled(1, 3, .{ .date = .{ .year = 2026, .month = 10, .day = 7 } }, iso_date);
    try results.set(2, 0, .{ .text = "Não, talvez" });
    try results.set(2, 1, .int(4));
    try results.setStyled(2, 2, .{ .number = 0.25 }, .{ .number_format = .percent });
    try results.setStyled(2, 3, .{ .datetime = try .fromUnix(1_791_378_061) }, iso_datetime);
    try results.setStyled(3, 0, .{ .text = "Total" }, .{ .bold = true });
    try results.set(3, 1, .{ .formula = "=SUM(B2:B3)" });
    try results.set(3, 2, .{ .boolean = true });
    try results.set(3, 3, .{ .text = "=1+1" });
    try results.set(4, 0, .{ .text = "He said \"hi\"" });
    try results.setStyled(4, 1, .{ .number = 1234.5 }, .{ .number_format = .{ .custom = "0.00" }, .border = .medium });
    try results.set(4, 2, .{ .text = "  padded  " });
    try results.set(4, 3, .{ .text = "a<b&c>d" });
    try results.setStyled(5, 0, .{ .date = .{ .year = 1900, .month = 3, .day = 1 } }, iso_date);
    try results.set(5, 1, .{ .number = -0.5 });
    try results.set(5, 2, .{ .text = "+55 11 99999-0000" });
    try results.set(5, 3, .{ .text = "@handle" });
    try results.freeze(1, 0);
    try results.setAutoFilter(.{ .first_row = 0, .first_col = 0, .last_row = 2, .last_col = 3 });

    const votes = try wb.addSheet("Votes");
    try votes.setRow(0, 0, &.{ .{ .text = "Unidade" }, .{ .text = "Opção" } }, header);
    try votes.setRow(1, 0, &.{ .{ .text = "101" }, .{ .text = "Sim" } }, .{});
    try votes.setRow(2, 0, &.{ .{ .text = "Bloco A — 12" }, .{ .text = "Não" } }, .{});
    try votes.freeze(1, 1);
    return wb;
}

/// The CSV export filter options: comma, double quote, UTF-8, from
/// line 1, no column formats, en-US, quote only when needed, detect
/// numbers, cells as shown, no formulas, keep spaces, every sheet (one
/// "sample-<sheet>.csv" each).
const csv_filter = "csv:Text - txt - csv (StarCalc):44,34,76,1,,1033,false,true,true,false,false,-1";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = arg_it.next(); // executable name
    const work_path = arg_it.next() orelse return error.MissingWorkDirectory;

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, work_path);
    var work = try cwd.openDir(io, work_path, .{});
    defer work.close(io);
    // LibreOffice needs absolute paths (the profile is a file:// URL).
    const work_abs = try cwd.realPathFileAlloc(io, work_path, gpa);
    defer gpa.free(work_abs);

    {
        const wb = try buildSample(gpa);
        defer wb.deinit();
        var file = try work.createFile(io, "sample.xlsx", .{});
        defer file.close(io);
        var buffer: [8192]u8 = undefined;
        var file_writer = file.writer(io, &buffer);
        try wb.writeTo(&file_writer.interface);
        try file_writer.interface.flush();
    }

    const profile = try std.fmt.allocPrint(gpa, "-env:UserInstallation=file://{s}/profile", .{work_abs});
    defer gpa.free(profile);
    const sample = try std.fmt.allocPrint(gpa, "{s}/sample.xlsx", .{work_abs});
    defer gpa.free(sample);
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "soffice", "--headless", "--norestore", profile, "--convert-to", csv_filter, "--outdir", work_abs, sample },
    }) catch |err| {
        std.debug.print("cannot run soffice (is LibreOffice installed?): {t}\n", .{err});
        std.process.exit(1);
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (!result.term.success()) {
        std.debug.print("soffice failed.\n--- stdout\n{s}--- stderr\n{s}---\n", .{ result.stdout, result.stderr });
        std.process.exit(1);
    }

    var failed = false;
    for ([_][2][]const u8{
        .{ "sample-Results.csv", results_csv },
        .{ "sample-Votes.csv", votes_csv },
    }) |case| {
        const actual = work.readFileAlloc(io, case[0], gpa, .limited(1 << 20)) catch |err| {
            std.debug.print("{s}: cannot read LibreOffice's output: {t}\n--- soffice stdout\n{s}--- soffice stderr\n{s}---\n", .{ case[0], err, result.stdout, result.stderr });
            failed = true;
            continue;
        };
        defer gpa.free(actual);
        if (!std.mem.eql(u8, actual, case[1])) {
            std.debug.print("{s}: LibreOffice saw different cells.\n--- expected\n{s}--- actual\n{s}---\n", .{ case[0], case[1], actual });
            failed = true;
        }
    }

    // The reader, on our own file.
    {
        const got = try readBack(gpa, io, work, "sample.xlsx");
        defer gpa.free(got);
        if (!std.mem.eql(u8, got, results_read)) {
            std.debug.print("sample.xlsx: the reader gave different cells.\n--- expected\n{s}--- actual\n{s}---\n", .{ results_read, got });
            failed = true;
        }
    }

    // The reader, on a workbook made by LibreOffice from a CSV file.
    {
        try work.writeFile(io, .{ .sub_path = "import.csv", .data = import_csv });
        const csv_path = try std.fmt.allocPrint(gpa, "{s}/import.csv", .{work_abs});
        defer gpa.free(csv_path);
        const converted = std.process.run(gpa, io, .{
            .argv = &.{ "soffice", "--headless", "--norestore", profile, "--infilter=CSV:44,34,76,1,,1033,false,true", "--convert-to", "xlsx", "--outdir", work_abs, csv_path },
        }) catch |err| {
            std.debug.print("cannot run soffice: {t}\n", .{err});
            std.process.exit(1);
        };
        defer gpa.free(converted.stdout);
        defer gpa.free(converted.stderr);
        const got = readBack(gpa, io, work, "import.xlsx") catch |err| {
            std.debug.print("import.xlsx (made by LibreOffice): the reader failed: {t}\n--- soffice stderr\n{s}---\n", .{ err, converted.stderr });
            std.process.exit(1);
        };
        defer gpa.free(got);
        if (!std.mem.eql(u8, got, import_read)) {
            std.debug.print("import.xlsx (made by LibreOffice): the reader gave different cells.\n--- expected\n{s}--- actual\n{s}---\n", .{ import_read, got });
            failed = true;
        }
    }
    if (failed) std.process.exit(1);
}
