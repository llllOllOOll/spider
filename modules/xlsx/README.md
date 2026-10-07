# spider.xlsx

Writes and reads Excel `.xlsx` files. Pure Zig, `std` only: no C, no global
state, no temporary files.

- **Writing** (export): the file is built in memory and returned as bytes or
  written to any `std.Io.Writer`.
- **Reading** (import): a file's bytes are opened with limits and each sheet
  is read as a stream of typed rows, in bounded memory. See
  [Reading](#reading).

It is an **opt-in** module: a project that does not ask for it does not
compile it.

## Enabling it

In the app's `build.zig`, where the Spider dependency is declared:

```zig
const spider_dep = b.dependency("spider", .{ .target = target, .optimize = optimize, .xlsx = true });
```

Then `spider.xlsx` is available. Without `.xlsx = true`, any use of
`spider.xlsx` is a compile error (`no module named 'spider_xlsx'`); Spider's
own `zig build test` checks exactly that.

When working on Spider itself: `zig build -Dxlsx=true`.

The module imports nothing from Spider, so it can also be used on its own:
depend on `modules/xlsx` and import the `spider_xlsx` module.

## Example

```zig
const std = @import("std");
const spider = @import("spider");
const xlsx = spider.xlsx;

fn exportPoll(c: *spider.Ctx) !spider.Response {
    const wb = try xlsx.Workbook.init(c.arena);
    defer wb.deinit();

    const sheet = try wb.addSheet("Result");
    try sheet.setColumnWidth(0, 30);

    const header: xlsx.Style = .{ .bold = true, .fill = 0xDDEEFF, .border = .thin };
    try sheet.setRow(0, 0, &.{ .{ .text = "Option" }, .{ .text = "Votes" }, .{ .text = "%" } }, header);

    try sheet.set(1, 0, .{ .text = "Yes" });
    try sheet.set(1, 1, .int(12));
    try sheet.setStyled(1, 2, .{ .number = 0.75 }, .{ .number_format = .percent });

    try sheet.set(2, 0, .{ .text = "Closed at" });
    try sheet.set(2, 1, .{ .datetime = try .fromUnix(1_791_378_061) }); // UTC

    try sheet.set(3, 1, .{ .formula = "SUM(B2:B2)" });

    try sheet.freeze(1, 0); // keep the header row in view
    try sheet.setAutoFilter(.{ .first_row = 0, .first_col = 0, .last_row = 1, .last_col = 2 });

    const bytes = try wb.toOwnedSlice(c.arena);
    return .{
        .body = bytes,
        .headers = &.{
            .{ "Content-Type", xlsx.content_type },
            .{ "Content-Disposition", "attachment; filename=\"poll.xlsx\"" },
        },
    };
}
```

Rows and columns are zero-based. Cells can be set in any order; setting a
cell again replaces it. Text, sheet names, formulas and format codes are
copied, so the caller's buffers can be reused right away.

## API

| | |
|---|---|
| `Workbook.init(gpa)` / `deinit()` | Creates and frees a workbook. |
| `wb.setDefaultFont(name, size)` | The font of unstyled cells (Calibri 11 otherwise); call it first. |
| `wb.addSheet(name)` | Adds a sheet (Excel's naming rules apply). |
| `sheet.set(row, col, value)` | Sets a cell. |
| `sheet.setStyled(row, col, value, style)` | Sets a cell and its style. |
| `sheet.setRow(row, first_col, values, style)` | Sets consecutive cells of a row. |
| `sheet.setColumnWidth(col, characters)` | Column width, 0 to 255. |
| `sheet.setRowHeight(row, points)` | Row height, 0 to 409. |
| `sheet.setRowHeightHint(row, points)` | A height the program may refit. |
| `sheet.setDefaultColumnWidth(characters)` / `setDefaultRowHeight(points)` | For columns and rows without their own. |
| `sheet.hideColumn(col)` / `hideRow(row)` | Hides a column or a row. |
| `sheet.mergeCells(range)` | Merges a rectangle of cells into one. |
| `sheet.setLink(row, col, target)` | Links a cell to a site or an e-mail address. |
| `sheet.setZoom(percent)` | Zoom on screen, 10 to 400. |
| `sheet.setPageSetup(.{ .paper, .orientation, .margins, .scale, .fit_to_width, .fit_to_height })` | How the sheet is printed. |
| `sheet.setPrintTitleRows(first, last)` | Rows repeated on every printed page. |
| `sheet.setPrintArea(range)` | Prints only that range. |
| `sheet.addPageBreakBeforeRow(row)` / `addPageBreakBeforeColumn(col)` | Manual page breaks. |
| `sheet.setHeaderFooter(.{ .header, .footer })` | Text at the top and bottom of each page (`&P`, `&N`, `&L`, `&C`, `&R`). |
| `sheet.protect(.{ .password })` / `wb.protect(.{ .password })` | Locks the cells of a sheet / the workbook's structure. |
| `sheet.freeze(rows, cols)` | Frozen panes; `freeze(1, 0)` pins a header. |
| `sheet.setAutoFilter(range)` | Filter buttons on the range's first row. |
| `wb.toOwnedSlice(allocator)` | The file as bytes. |
| `wb.writeTo(writer)` | The file to any `*std.Io.Writer` (flush it afterwards). |
| `wb.writeToPackager(packager)` | The parts to a custom container. |

Values (`xlsx.Value`): `.blank`, `.{ .text = … }`, `.{ .number = … }`,
`.int(n)`, `.{ .boolean = … }`, `.{ .date = … }`, `.{ .datetime = … }`,
`.{ .formula = … }`.

Style (`xlsx.Style`):

- font: `bold`, `italic`, `underline`, `font_color` (`0xRRGGBB`),
  `font_name` (e.g. `"Times New Roman"`), `font_size` (points);
- `fill` (`0xRRGGBB`), `fill_pattern` (solid by default, or grey dot
  patterns);
- `border` (`.hair`, `.dotted`, `.dashed`, `.thin`, `.medium`, `.thick`,
  `.double`, on the four sides), with `border_left`, `border_right`,
  `border_top` and `border_bottom` to set or remove one side, and
  `border_color`;
- `unlocked`, for cells that stay editable on a protected sheet;
- alignment: `h_align` (`.left`, `.center`, `.right`), `v_align` (`.top`,
  `.center`, `.bottom`), `wrap`, `shrink`;
- `number_format`: `.integer`, `.decimal`, `.thousands`,
  `.thousands_decimal`, `.percent`, `.percent_decimal`, `.date`, `.time`,
  `.datetime`, `.text`, or `.{ .custom = "dd/mm/yyyy" }`.

A style is a plain value: build one, copy it, change a field.

## What to know

- **User text is never a formula.** `.text` is written as text whatever it
  starts with (`=`, `+`, `-`, `@`): it shows as typed and is not evaluated.
  Only `.formula` writes a formula, so never build one from user input.
- **Formulas carry no result.** The program that opens the file calculates
  them (the workbook asks for it). Viewers that do not calculate show
  nothing; write the number yourself when that matters.
- **Dates** are numbers with a date format, in the 1900 date system. A date
  or date-time gets the reader's short date format unless the style names a
  number format. `DateTime.fromUnix` gives UTC; add the zone offset to the
  timestamp first for local time.
- **Limits** are Excel's and are checked when a value is set: 1,048,576
  rows, 16,384 columns, 32,767 characters per cell, 8,192 per formula, 31
  per sheet name, 65,490 styles. Errors are values of `xlsx.Error`
  (`RowOutOfRange`, `TextTooLong`, `InvalidSheetName`, …); nothing is
  printed.
- **Line breaks need `wrap`.** A `\n` in text is kept, but a spreadsheet
  only shows it as a new line in a cell whose style has `wrap = true`.
- **Merged cells take their borders from every cell of the range.** Give
  the blank cells of the range the same style as the first one.
- **Links** accept only `http://`, `https://` and `mailto:` targets, so a
  link built from user data cannot point at a local file. A link does not
  change how its cell looks: use `xlsx.link_style` for the usual blue,
  underlined text.
- **Printing**: every sheet carries Excel's default margins. Without
  `setPageSetup` the reader's program chooses the paper (Letter or A4, by
  country), so the same sheet breaks into pages differently. Margins are in
  inches; `xlsx.cm(1.5)` converts. `scale` and `fit_to_width` /
  `fit_to_height` cannot be combined.
- **Protection is not security.** It stops editing by accident. The file
  is not encrypted and the password is stored as a 15-bit hash that many
  other passwords also match.
- **Hiding is not removing.** A hidden row or column is still in the file
  and one click shows it again.
- **Column widths depend on the default font.** A width is a number of
  characters of the workbook's default font, so the same value is narrower
  in a workbook whose default is Times New Roman 10 than in one that keeps
  Calibri 11. When copying the layout of an existing file, set the same
  default font.
- **Document numbers and zeros on the left**: write the number with a
  custom format such as `"00000000000"`, or write it as text.
- **Only what is used is written**: styles and texts that no cell ends up
  using are left out.
- **The output is deterministic**: the same calls give the same bytes.
- **The file is not compressed** (see below), so it is larger than what
  Excel saves: roughly the size of its XML.

## Reading

```zig
const std = @import("std");
const xlsx = @import("spider").xlsx;

fn printSheet(gpa: std.mem.Allocator, bytes: []const u8) !void {
    const book = try xlsx.Reader.open(gpa, bytes, .{});
    defer book.deinit();

    for (book.sheets()) |sheet| std.debug.print("{s} ({t})\n", .{ sheet.name, sheet.visibility });

    const rows = try book.rows(0, .{});
    defer rows.deinit();
    while (try rows.next()) |row| {
        for (row.cells) |cell| switch (cell.value) {
            .empty => {},
            .text => |text| std.debug.print("{d}:{d} text {s}\n", .{ row.number, cell.column, text }),
            .number => |n| std.debug.print("{d}:{d} number {d} ({s})\n", .{ row.number, cell.column, n, cell.format }),
            .boolean => |b| std.debug.print("{d}:{d} boolean {}\n", .{ row.number, cell.column, b }),
            .date => |d| std.debug.print("{d}:{d} date {d}-{d}-{d}\n", .{ row.number, cell.column, d.year, d.month, d.day }),
            .time => |t| std.debug.print("{d}:{d} time {d}:{d}\n", .{ row.number, cell.column, t.hour, t.minute }),
            .err => |e| std.debug.print("{d}:{d} error {s}\n", .{ row.number, cell.column, e }),
        };
    }
}
```

`bytes` must stay valid until `book.deinit()`. A row, its cells and their
texts are valid until the next `rows.next()`: copy what you keep.

| | |
|---|---|
| `Reader.open(gpa, bytes, limits)` | Opens a workbook; reads the sheet list and the number formats. |
| `Reader.openDiagnosed(gpa, bytes, limits, &diagnostic)` | The same, saying where a failure happened. |
| `book.sheets()` | Name and visibility of each sheet, in tab order. |
| `book.sheetIndex(name)` | Finds a sheet by name (ASCII case ignored). |
| `book.rows(index, .{ .formulas = false })` | An iterator over the rows of a sheet. |
| `rows.next()` | The next row the file has, or null. |
| `rows.mergedRanges()` | The sheet's merged ranges, complete after the last row. |
| `book.diagnostic` | Part, sheet, row, column, byte offset and limit of the last error. |

What to know:

- **Rows and cells are sparse.** Rows and columns the file does not have are
  not returned: use `row.number` and `cell.column` (zero-based), not the
  position in the iteration. A table's header is not always the first row,
  totals and notes may follow the data, and a sheet may be empty.
- **Empty cells are reported** (`.empty`) when the file has them: a cell
  with a border and no content, a formula never calculated.
- **Dates** are numbers in the file. A cell is a `.date` when its number
  format shows a date, in the 1900 or the 1904 system; a number below 1
  with a time format is a `.time`. Elapsed-time formats (`[h]:mm`) stay
  numbers, in days.
- **`cell.format`** is the number format code (`"General"`, `"0.00"`,
  `"dd/mm/yyyy"`, `"00000000000"`). A document number stored as
  `1234567890` with the format `"00000000000"` is the document
  `01234567890`: pad it yourself. The same column often mixes numbers and
  text typed by hand; expect both.
- **Formulas are never evaluated.** A formula cell gives the value its
  author's program last saved; with `.formulas = true`, `cell.formula` is
  its text. A file written by this module's writer has no saved results:
  its formula cells read as `.empty`.
- **Text** comes as stored: it can have spaces at the edges, line breaks
  (`\n`, sometimes `\r\n`) and control characters.
- **Errors** are `xlsx.ReadError`: `LimitExceeded`, `InvalidZip`,
  `InvalidXml`, `InvalidFile`, `Unsupported`, `Encrypted`, `SheetNotFound`,
  `OutOfMemory`. After an error the diagnostic says where, without any
  text from the file.

### Limits

Every limit is per call (`xlsx.ReadLimits`). The defaults are for files
uploaded by strangers; `xlsx.ReadLimits.large` is for big files from a
source you know.

| Limit | Default | `large` | What it bounds |
|---|---|---|---|
| `max_file_bytes` | 16 MiB | 256 MiB | The .xlsx file itself. |
| `max_entries` | 1,000 | 1,000 | Entries in the zip. |
| `max_part_bytes` | 64 MiB | 1 GiB | One part, uncompressed (a sheet's XML). |
| `max_total_bytes` | 128 MiB | 2 GiB | All parts, uncompressed. |
| `max_compression_ratio` | 200 | 1,000 | Uncompressed/compressed, for parts over 1 MiB. |
| `max_shared_strings_bytes` | 32 MiB | 256 MiB | Memory of the shared strings table. |
| `max_rows` | 100,000 | 1,048,576 | Rows read from one sheet. |
| `max_columns` | 16,384 | 16,384 | Highest column (Excel's limit). |
| `max_cell_text` | 32,767 | 32,767 | Characters in one cell (Excel's limit). |
| `max_merged_ranges` | 10,000 | 10,000 | Merged ranges kept per sheet. |
| `xml.max_depth` | 64 | 64 | Nested XML elements. |
| `xml.max_attributes` | 64 | 64 | Attributes on one element. |
| `xml.max_name_len` | 256 | 256 | Bytes in an XML name. |
| `xml.max_value_len` | 64 KiB | 64 KiB | Bytes in an attribute value. |
| `xml.max_tag_len` | 256 KiB | 256 KiB | Bytes in one start tag. |

What a read costs: the file's bytes (you hold them), the shared strings
table, the number formats, a 64 KiB decompression window, a 16 KiB XML
buffer and one row. A real export of 126,329 rows by 50 columns (6 million
cells, 205 MB of XML in a 43 MB file, 53,559 shared strings) reads in
about 3 seconds with the `large` profile, using about 2 MB beyond the file
itself. With the defaults that file is refused at the first check
(`max_file_bytes`).

A sheet that claims a cell at row 4,000,000,000 is `LimitExceeded`, never
billions of empty rows. Rows or cells out of order are `InvalidFile`. A
`<!DOCTYPE` in any part is `InvalidXml`: no entity is ever expanded.

### Importing an upload in a Spider handler

```zig
const std = @import("std");
const spider = @import("spider");
const xlsx = spider.xlsx;

/// Limits for a register typed by a person: a few thousand rows at most.
const import_limits: xlsx.ReadLimits = .{
    .max_file_bytes = 10 << 20, // Spider's own body limit (Config.max_body_bytes)
    .max_part_bytes = 32 << 20,
    .max_total_bytes = 48 << 20,
    .max_shared_strings_bytes = 8 << 20,
    .max_rows = 5_000,
    .max_columns = 50,
};

fn importPeople(c: *spider.Ctx) !spider.Response {
    var form = try c.parseMultipart();
    defer form.deinit();
    const files = form.getFile("planilha") orelse return error.BadRequest;
    if (files.len != 1) return error.BadRequest;

    var diagnostic: xlsx.ReadDiagnostic = .{};
    const book = xlsx.Reader.openDiagnosed(c.arena, files[0].data, import_limits, &diagnostic) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // Say what is wrong in the user's terms; log the diagnostic.
        error.Unsupported => return c.text("Envie um arquivo .xlsx (não .xls).", .{ .status = .unprocessable_entity }),
        error.Encrypted => return c.text("O arquivo está protegido por senha.", .{ .status = .unprocessable_entity }),
        error.LimitExceeded => return c.text("A planilha é grande demais.", .{ .status = .unprocessable_entity }),
        else => return c.text("Não foi possível ler a planilha.", .{ .status = .unprocessable_entity }),
    };
    defer book.deinit();

    const rows = try book.rows(0, .{});
    defer rows.deinit();
    var imported: usize = 0;
    while (rows.next() catch return c.text("A planilha está danificada ou é grande demais.", .{ .status = .unprocessable_entity })) |row| {
        if (row.number == 0) continue; // the header
        var name: ?[]const u8 = null;
        var document: ?u64 = null;
        for (row.cells) |cell| switch (cell.column) {
            0 => if (cell.value == .text) {
                name = std.mem.trim(u8, cell.value.text, " \t\r\n");
            },
            // The same column holds numbers in some rows and text in others.
            1 => document = switch (cell.value) {
                .number => |n| if (n >= 0 and n < 1e14 and @floor(n) == n) @intFromFloat(n) else null,
                .text => |text| std.fmt.parseInt(u64, std.mem.trim(u8, text, " .-/"), 10) catch null,
                else => null,
            },
            else => {},
        };
        // Validate before saving: a spreadsheet is user input.
        if (name == null or name.?.len == 0 or name.?.len > 200 or document == null) continue;
        imported += 1; // …insert into the database here, in one transaction
    }
    return c.json(.{ .imported = imported }, .{});
}
```

Advice for imports:

- **Treat every cell as user input.** Check types, lengths and ranges,
  escape on output as you would for a form field, and never build SQL,
  HTML or a formula from a cell.
- **Keep the limits tight.** A register has thousands of rows, not a
  million; `max_rows` and `max_columns` are the cheap way to say so.
- **Do the work in one transaction**, and tell the person which rows were
  skipped and why.
- **Read by column position or by header text, not by trust**: find the
  header row, map its labels to fields, and refuse a file whose headers you
  do not recognise.

### Not read

- **.xls** (the old binary format) and **.xlsb**: `error.Unsupported`.
  Convert them to .xlsx first (LibreOffice does it:
  `soffice --headless --convert-to xlsx file.xls`).
- **Files with a password to open**: `error.Encrypted`.
- **Macros**: an .xlsm is read as data; its macros are ignored and never
  run.
- zip64 archives (files past 4 GiB) and compression methods other than
  deflate.
- Styles other than the number format, column widths and hidden columns,
  comments, images, charts, pivot tables, data validation, conditional
  formatting, defined names.
- The reader does not write: a file cannot be opened, changed and saved.

## Not supported

When writing: streamed writing for very large sheets, compression, zip64
(files or parts past 4 GiB), links to other cells or files, a different
colour per border side, column default styles, different first-page or
even-page headers, columns repeated when printing, gridline and centring
print options, hidden sheets, grouped rows, conditional formatting, data
validation, encryption, rich text inside a cell,
comments, images, charts, pivot tables, the 1904 date system, document
properties and themes, editing an existing file.

## Design notes

A `.xlsx` is a zip archive of XML parts. The code keeps those two things
apart:

- `src/workbook.zig` builds each part — a name and its XML — with functions
  that only need a `*std.Io.Writer`, and hands the parts to a `Packager`.
- `src/zip.zig` has the `Packager` interface (`addPart(name, content)`,
  `finish()`) and `StoreZip`, the packager used by default: stored entries
  (no compression) with the CRC-32 and sizes in the local header, fixed
  1980-01-01 timestamps, no data descriptors, no zip64.

Parts written, in order: `[Content_Types].xml`, `_rels/.rels`,
`xl/workbook.xml`, `xl/_rels/workbook.xml.rels`,
`xl/worksheets/sheetN.xml` (each followed by
`xl/worksheets/_rels/sheetN.xml.rels` when the sheet has links),
`xl/styles.xml`, and `xl/sharedStrings.xml` when there is text.

What that leaves open:

- **Compression**: the place is marked in `StoreZip.addPart`. Deflate the
  content with `std.compress.flate` (container `.raw`), write method 8 and
  the compressed size; nothing outside `zip.zig` changes. Or pass another
  `Packager` to `writeToPackager`.
- **Streamed writing**: rows would go to the worksheet part as they arrive
  instead of being kept. That needs a packager that hands out a writer per
  part and writes sizes after the data (a zip data descriptor), and it needs
  the shared strings and styles to be known late — the reason streaming
  writers use inline strings. The part functions already write to a
  `*std.Io.Writer`.
- **Reading** is three layers, each usable alone: `src/zip_reader.zig`
  (an archive in memory, checked against its central directory, read in
  pieces with the CRC-32 verified at the end; `std.zip` only reads from a
  file and verifies nothing), `src/xml_reader.zig` (a pull parser with a
  small buffer that refuses `<!DOCTYPE` and undefined entities) and
  `src/reader.zig` (workbook, relationships, number formats, shared
  strings, and the row iterator). The decompressor is always given a
  window buffer: without one it can stall on some inputs in the Zig
  versions this module supports.

## Tests

- `zig build test` here, or `zig build test-xlsx` at Spider's root: unit
  tests. For the writer they fix the XML of every part, the zip bytes,
  dates, escaping, Excel's limits, formula injection, determinism, hostile
  names and a round trip through `std.zip` with CRC checks. For the reader:
  a round trip with the writer, hand-written XML in the style of other
  producers, one hostile case per limit (zip bomb, too many entries,
  repeated and escaping names, truncation, wrong CRC and sizes, encryption,
  zip64, DOCTYPE and entities, absurd counts and references, deep nesting,
  huge attributes, invalid UTF-8), every prefix of a valid file, and
  thousands of single-byte corruptions that must fail cleanly or read
  exactly as the intact file. Both sides: an allocation failure at any
  point leaks nothing.
- `zig build test-libreoffice` here: writes a sample workbook, has headless
  LibreOffice (`soffice`) convert it to CSV and compares the cells; reads
  that workbook back; and reads a workbook LibreOffice makes from a CSV
  file. Needs LibreOffice installed.
- `zig build sample-files` here: writes three workbooks to
  `zig-out/sample-files` for checking by hand in Excel, Google Sheets and
  Numbers, which the automated tests cannot drive (every feature once, a
  200-row poll export, and the size limits). The data is made up.
- Spider's `zig build test` checks the opt-in: without `-Dxlsx=true` a
  probe that uses `spider.xlsx` must fail to compile; with it, the probe
  runs.
