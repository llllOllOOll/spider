# spider.xlsx

Writes Excel `.xlsx` files. Pure Zig, `std` only: no C, no global state, no
temporary files. The file is built in memory and returned as bytes or written
to any `std.Io.Writer`.

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
| `wb.addSheet(name)` | Adds a sheet (Excel's naming rules apply). |
| `sheet.set(row, col, value)` | Sets a cell. |
| `sheet.setStyled(row, col, value, style)` | Sets a cell and its style. |
| `sheet.setRow(row, first_col, values, style)` | Sets consecutive cells of a row. |
| `sheet.setColumnWidth(col, characters)` | Column width, 0 to 255. |
| `sheet.freeze(rows, cols)` | Frozen panes; `freeze(1, 0)` pins a header. |
| `sheet.setAutoFilter(range)` | Filter buttons on the range's first row. |
| `wb.toOwnedSlice(allocator)` | The file as bytes. |
| `wb.writeTo(writer)` | The file to any `*std.Io.Writer` (flush it afterwards). |
| `wb.writeToPackager(packager)` | The parts to a custom container. |

Values (`xlsx.Value`): `.blank`, `.{ .text = … }`, `.{ .number = … }`,
`.int(n)`, `.{ .boolean = … }`, `.{ .date = … }`, `.{ .datetime = … }`,
`.{ .formula = … }`.

Style (`xlsx.Style`): `bold`, `fill` (`0xRRGGBB`), `border` (`.thin`,
`.medium`, `.thick`), `number_format` (`.integer`, `.decimal`, `.thousands`,
`.thousands_decimal`, `.percent`, `.percent_decimal`, `.date`, `.time`,
`.datetime`, `.text`, or `.{ .custom = "dd/mm/yyyy" }`).

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
- **Only what is used is written**: styles and texts that no cell ends up
  using are left out.
- **The output is deterministic**: the same calls give the same bytes.
- **The file is not compressed** (see below), so it is larger than what
  Excel saves: roughly the size of its XML.

## Not supported

Reading files, streamed writing for very large sheets, compression, zip64
(files or parts past 4 GiB), merged cells, text colour, italics, alignment,
row heights, hyperlinks, comments, images, charts, pivot tables, the 1904
date system, document properties and themes, editing an existing file.

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
`xl/worksheets/sheetN.xml`, `xl/styles.xml`, and `xl/sharedStrings.xml` when
there is text.

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
- **Reading**: a reader is the mirror image and would live beside the
  writer: a zip reader over bytes in memory (`std.zip` only reads from a
  file and does not verify checksums), a small pull XML parser, then
  `xl/workbook.xml` and its relationships to find the sheets,
  `sharedStrings.xml` and `styles.xml` loaded first, and an iterator of rows
  with typed cells. `cell_ref.zig`, `date.zig` (serial to date) and the
  number-format ids in `styles.zig` are the shared pieces. It must enforce
  limits on decompressed size, entry count, shared strings and row/column
  references, and refuse `<!DOCTYPE`.

## Tests

- `zig build test` here, or `zig build test-xlsx` at Spider's root: unit
  tests. They fix the XML of every part, the zip bytes, dates, escaping,
  Excel's limits, formula injection, determinism, hostile names, a round
  trip through `std.zip` with CRC checks, and that an allocation failure at
  any point leaks nothing.
- `zig build test-libreoffice` here: writes a sample workbook, has headless
  LibreOffice (`soffice`) convert it to CSV and compares the cells. Needs
  LibreOffice installed.
- Spider's `zig build test` checks the opt-in: without `-Dxlsx=true` a
  probe that uses `spider.xlsx` must fail to compile; with it, the probe
  runs.
