//! Reads .xlsx files: the import side of the module.
//!
//! A `Reader` is opened over the bytes of a file (an upload, for
//! instance), lists the sheets, and hands out a `Rows` iterator per
//! sheet. Rows are parsed as they are asked for, straight from the
//! compressed part, so a sheet of any size is read in bounded memory:
//! what stays in memory is the shared strings table, the list of
//! number formats and one row at a time.
//!
//! Nothing is evaluated: a formula cell gives the value its author's
//! program last computed. Everything read is checked against `Limits`,
//! whose defaults suit files uploaded by strangers.
//!
//! Not read: .xls and .xlsb (other formats), encrypted files, charts,
//! images, comments, styles other than the number format.

const std = @import("std");
const zip_reader = @import("zip_reader.zig");
const zip_writer = @import("zip.zig");
const xml_reader = @import("xml_reader.zig");
const cell_ref = @import("cell_ref.zig");
const date_mod = @import("date.zig");

pub const DateTime = date_mod.DateTime;
pub const TimeOfDay = date_mod.TimeOfDay;
pub const Range = cell_ref.Range;

pub const Error = error{
    /// One of `Limits` was exceeded; `Diagnostic.limit` says which.
    LimitExceeded,
    /// Not a zip archive, or a damaged one.
    InvalidZip,
    /// A part is not well-formed XML (or has a document type
    /// declaration, which is never accepted).
    InvalidXml,
    /// A valid zip and valid XML, but not a workbook this reader
    /// understands: a part is missing, a reference is malformed, rows
    /// or cells are out of order, a number is not a number.
    InvalidFile,
    /// Not an .xlsx: an old .xls, an .xlsb, a zip64 archive, a
    /// compression method other than deflate, or a sheet that is not a
    /// worksheet.
    Unsupported,
    /// The file is protected by a password to open.
    Encrypted,
    SheetNotFound,
    OutOfMemory,
};

/// How much a file may ask of the server before it is refused.
///
/// The defaults are meant for files uploaded by people you do not
/// know: they accept any ordinary spreadsheet and bound the memory and
/// time a hostile one can take. `Limits.large` is for files you expect
/// to be big.
pub const Limits = struct {
    /// Size of the .xlsx file itself.
    max_file_bytes: u64 = 16 << 20,
    /// Entries in the zip archive.
    max_entries: u32 = 1_000,
    /// Uncompressed size of one part (a sheet's XML, for instance).
    max_part_bytes: u64 = 64 << 20,
    /// Uncompressed size of all parts together.
    max_total_bytes: u64 = 128 << 20,
    /// Uncompressed/compressed ratio of one part larger than 1 MiB.
    max_compression_ratio: u32 = 200,
    /// Memory the shared strings table may take. It is the one thing
    /// that has to be loaded whole before a sheet is read.
    max_shared_strings_bytes: u64 = 32 << 20,
    /// Rows read from one sheet.
    max_rows: u32 = 100_000,
    /// Columns: a cell beyond this is an error. Excel's limit.
    max_columns: u32 = 16_384,
    /// Characters in one cell's text, counted as Excel does. Excel's limit.
    max_cell_text: u32 = 32_767,
    /// Merged ranges kept per sheet.
    max_merged_ranges: u32 = 10_000,
    /// Depth, attributes and sizes of the XML itself.
    xml: xml_reader.Limits = .{},

    /// For large files from a known source (an ERP export of a hundred
    /// thousand rows, say): files up to 256 MiB, parts up to 1 GiB, a
    /// full sheet of rows, 256 MiB of shared strings. Reading stays
    /// streamed, but the shared strings table alone may now take up to
    /// 256 MiB of memory, and parsing a gigabyte of XML takes tens of
    /// seconds of CPU: do not use it for uploads by strangers.
    pub const large: Limits = .{
        .max_file_bytes = 256 << 20,
        .max_part_bytes = 1 << 30,
        .max_total_bytes = 2 << 30,
        .max_compression_ratio = 1_000,
        .max_shared_strings_bytes = 256 << 20,
        .max_rows = 1_048_576,
    };
};

pub const LimitKind = enum {
    file_bytes,
    entries,
    part_bytes,
    total_bytes,
    compression_ratio,
    shared_strings_bytes,
    rows,
    columns,
    cell_text,
    merged_ranges,
    xml,
};

/// Which part of the file was being read.
pub const Part = enum { none, package, workbook, styles, shared_strings, sheet };

/// Where the last error happened. It never holds text from the file.
pub const Diagnostic = struct {
    part: Part = .none,
    /// Index of the sheet, when `part` is `.sheet`.
    sheet: ?usize = null,
    /// Zero-based row and column being read, when known.
    row: ?u32 = null,
    column: ?u32 = null,
    /// How far into the part's XML the reader was, in bytes.
    byte_offset: ?u64 = null,
    /// For `error.LimitExceeded`: the limit.
    limit: ?LimitKind = null,
};

pub const Visibility = enum { visible, hidden, very_hidden };

pub const SheetInfo = struct {
    name: []const u8,
    visibility: Visibility,
};

/// What a cell holds.
pub const Value = union(enum) {
    /// A cell with formatting and no content, or a formula never
    /// calculated.
    empty,
    text: []const u8,
    number: f64,
    boolean: bool,
    /// A number shown as a date (see `Cell.format`), converted. The
    /// time of day is in it too.
    date: DateTime,
    /// A number between 0 and 1 shown as a time.
    time: TimeOfDay,
    /// An error value such as `#DIV/0!` or `#N/A`, as text.
    err: []const u8,
};

pub const Cell = struct {
    /// Zero-based.
    column: u32,
    value: Value,
    /// The cell's number format code, `"General"` when it has none.
    /// It tells how the author meant a number to be shown: with
    /// `"00000000000"`, 1234567890 is the document 01234567890.
    format: []const u8,
    /// The formula's text without `=`, when `Options.formulas` is set
    /// and the cell has one. It is never evaluated.
    formula: ?[]const u8 = null,
};

/// One row of a sheet. `cells` and the texts in it are valid until the
/// next call to `Rows.next`.
pub const Row = struct {
    /// Zero-based. Rows the file does not have are simply not
    /// returned: numbers can jump.
    number: u32,
    hidden: bool,
    /// In column order; columns can jump too.
    cells: []const Cell,
};

pub const Options = struct {
    /// Also return each formula's text.
    formulas: bool = false,
};

const NumberKind = enum { number, date, time, duration };

const Format = struct {
    code: []const u8,
    kind: NumberKind,
};

const general: Format = .{ .code = "General", .kind = .number };

pub const Reader = struct {
    gpa: std.mem.Allocator,
    /// Owns what lives as long as the reader: names, formats.
    arena: std.heap.ArenaAllocator,
    archive: zip_reader.Archive,
    limits: Limits,
    /// Where the last error happened.
    diagnostic: Diagnostic = .{},
    sheet_list: []SheetInfo = &.{},
    /// Null for a sheet that is not a worksheet.
    sheet_parts: []?*const zip_reader.Entry = &.{},
    date_system: date_mod.DateSystem = .excel_1900,
    formats: []Format = &.{},
    strings_part: ?*const zip_reader.Entry = null,
    strings_loaded: bool = false,
    /// Every shared string, back to back, and where each one ends.
    string_data: std.ArrayList(u8) = .empty,
    string_ends: std.ArrayList(u32) = .empty,

    /// Opens a workbook from the bytes of an .xlsx file. `bytes` must
    /// stay valid until `deinit`. Reads the sheet list and the number
    /// formats; sheets are read by `rows`.
    pub fn open(gpa: std.mem.Allocator, bytes: []const u8, limits: Limits) Error!*Reader {
        var diagnostic: Diagnostic = .{};
        return openDiagnosed(gpa, bytes, limits, &diagnostic);
    }

    /// Like `open`; when it fails, `diagnostic` says where.
    pub fn openDiagnosed(gpa: std.mem.Allocator, bytes: []const u8, limits: Limits, diagnostic: *Diagnostic) Error!*Reader {
        diagnostic.* = .{ .part = .package };
        if (bytes.len > limits.max_file_bytes) {
            diagnostic.limit = .file_bytes;
            return error.LimitExceeded;
        }
        // An OLE container: an old .xls, or an encrypted workbook.
        if (std.mem.startsWith(u8, bytes, "\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1")) {
            const marker = "E\x00n\x00c\x00r\x00y\x00p\x00t\x00e\x00d\x00P\x00a\x00c\x00k\x00a\x00g\x00e\x00";
            return if (std.mem.indexOf(u8, bytes, marker) != null) error.Encrypted else error.Unsupported;
        }

        var zip_limit: ?zip_reader.LimitKind = null;
        var archive = zip_reader.Archive.openDiagnosed(gpa, bytes, .{
            .max_entries = limits.max_entries,
            .max_part_bytes = limits.max_part_bytes,
            .max_total_bytes = limits.max_total_bytes,
            .max_compression_ratio = limits.max_compression_ratio,
        }, &zip_limit) catch |err| {
            if (zip_limit) |kind| diagnostic.limit = switch (kind) {
                .entries => .entries,
                .part_bytes => .part_bytes,
                .total_bytes => .total_bytes,
                .compression_ratio => .compression_ratio,
            };
            return err;
        };
        errdefer archive.deinit();

        const self = try gpa.create(Reader);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .arena = .init(gpa), .archive = archive, .limits = limits };
        errdefer self.arena.deinit();
        self.load() catch |err| {
            diagnostic.* = self.diagnostic;
            return err;
        };
        return self;
    }

    pub fn deinit(self: *Reader) void {
        const gpa = self.gpa;
        self.string_data.deinit(gpa);
        self.string_ends.deinit(gpa);
        self.arena.deinit();
        self.archive.deinit();
        gpa.destroy(self);
    }

    /// The sheets, in the order of the workbook's tabs.
    pub fn sheets(self: *const Reader) []const SheetInfo {
        return self.sheet_list;
    }

    /// Finds a sheet by name, ignoring the case of ASCII letters.
    pub fn sheetIndex(self: *const Reader, name: []const u8) ?usize {
        for (self.sheet_list, 0..) |sheet, index| {
            if (std.ascii.eqlIgnoreCase(sheet.name, name)) return index;
        }
        return null;
    }

    /// Starts reading the rows of a sheet. Free the iterator with
    /// `Rows.deinit`; several can be open at once.
    pub fn rows(self: *Reader, sheet: usize, options: Options) Error!*Rows {
        if (sheet >= self.sheet_list.len) return error.SheetNotFound;
        self.diagnostic = .{ .part = .sheet, .sheet = sheet };
        const entry = self.sheet_parts[sheet] orelse return error.Unsupported;
        try self.loadStrings();
        self.diagnostic = .{ .part = .sheet, .sheet = sheet };
        return Rows.create(self, sheet, entry, options);
    }

    fn exceeded(self: *Reader, kind: LimitKind) Error {
        self.diagnostic.limit = kind;
        return error.LimitExceeded;
    }

    /// Reads the package relationships, the workbook and the styles.
    fn load(self: *Reader) Error!void {
        const arena = self.arena.allocator();
        self.diagnostic = .{ .part = .package };
        if (self.archive.find("xl/workbook.bin") != null) return error.Unsupported;

        // The package says where its workbook is.
        var workbook_path: []const u8 = "xl/workbook.xml";
        if (self.archive.find("_rels/.rels")) |entry| {
            const relationships = try self.readRelationships(entry, "");
            for (relationships) |r| {
                if (std.mem.endsWith(u8, r.kind, "/officeDocument")) workbook_path = r.target;
            }
        }
        const workbook_entry = self.archive.find(workbook_path) orelse return error.InvalidFile;
        const directory = if (std.mem.lastIndexOfScalar(u8, workbook_path, '/')) |slash| workbook_path[0..slash] else "";
        const file_name = workbook_path[if (directory.len > 0) directory.len + 1 else 0..];

        self.diagnostic = .{ .part = .workbook };
        const SheetRef = struct { name: []const u8, visibility: Visibility, id: []const u8 };
        var refs: std.ArrayList(SheetRef) = .empty;
        {
            const part = try PartReader.create(self, workbook_entry);
            defer part.destroy();
            while (true) {
                switch (try part.next()) {
                    .start => |name| {
                        if (std.mem.eql(u8, name, "workbookPr")) {
                            if (part.parser.attribute("date1904")) |v| {
                                if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true")) self.date_system = .excel_1904;
                            }
                        } else if (std.mem.eql(u8, name, "sheet") and part.parser.depth() == 3) {
                            const sheet_name = part.parser.attribute("name") orelse return error.InvalidFile;
                            const id = part.parser.attributeLocal("id") orelse return error.InvalidFile;
                            const state = part.parser.attribute("state") orelse "visible";
                            try refs.append(arena, .{
                                .name = try arena.dupe(u8, sheet_name),
                                .visibility = if (std.mem.eql(u8, state, "hidden")) .hidden else if (std.mem.eql(u8, state, "veryHidden")) .very_hidden else .visible,
                                .id = try arena.dupe(u8, id),
                            });
                        }
                    },
                    .eof => break,
                    else => {},
                }
            }
        }
        if (refs.items.len == 0) return error.InvalidFile;

        // The workbook's relationships say which part each sheet is.
        const rels_path = try std.fmt.allocPrint(arena, "{s}{s}_rels/{s}.rels", .{ directory, if (directory.len > 0) "/" else "", file_name });
        const rels_entry = self.archive.find(rels_path) orelse return error.InvalidFile;
        const relationships = try self.readRelationships(rels_entry, directory);

        self.sheet_list = try arena.alloc(SheetInfo, refs.items.len);
        self.sheet_parts = try arena.alloc(?*const zip_reader.Entry, refs.items.len);
        for (refs.items, self.sheet_list, self.sheet_parts) |ref, *info, *part| {
            info.* = .{ .name = ref.name, .visibility = ref.visibility };
            const relationship = for (relationships) |r| {
                if (std.mem.eql(u8, r.id, ref.id)) break r;
            } else return error.InvalidFile;
            if (std.mem.endsWith(u8, relationship.kind, "/worksheet")) {
                part.* = self.archive.find(relationship.target) orelse return error.InvalidFile;
            } else part.* = null; // a chart sheet, a macro sheet
        }

        var styles_entry = self.archive.find("xl/styles.xml");
        self.strings_part = self.archive.find("xl/sharedStrings.xml");
        for (relationships) |r| {
            if (std.mem.endsWith(u8, r.kind, "/styles")) styles_entry = self.archive.find(r.target);
            if (std.mem.endsWith(u8, r.kind, "/sharedStrings")) self.strings_part = self.archive.find(r.target);
        }
        if (styles_entry) |entry| try self.loadStyles(entry);
        self.diagnostic = .{};
    }

    const Relationship = struct { id: []const u8, kind: []const u8, target: []const u8 };

    /// Reads a relationships part. Targets come back as part names,
    /// resolved against `directory`.
    fn readRelationships(self: *Reader, entry: *const zip_reader.Entry, directory: []const u8) Error![]Relationship {
        const arena = self.arena.allocator();
        var list: std.ArrayList(Relationship) = .empty;
        const part = try PartReader.create(self, entry);
        defer part.destroy();
        while (true) {
            switch (try part.next()) {
                .start => |name| if (std.mem.eql(u8, name, "Relationship")) {
                    const mode = part.parser.attribute("TargetMode") orelse "Internal";
                    if (!std.mem.eql(u8, mode, "Internal")) continue; // a link out of the file
                    const id = part.parser.attribute("Id") orelse return error.InvalidFile;
                    const kind = part.parser.attribute("Type") orelse return error.InvalidFile;
                    const target = part.parser.attribute("Target") orelse return error.InvalidFile;
                    try list.append(arena, .{
                        .id = try arena.dupe(u8, id),
                        .kind = try arena.dupe(u8, kind),
                        .target = try resolvePath(arena, directory, target),
                    });
                },
                .eof => break,
                else => {},
            }
        }
        return list.items;
    }

    /// Reads the number formats: for each cell format record, its
    /// format code and whether it shows a date.
    fn loadStyles(self: *Reader, entry: *const zip_reader.Entry) Error!void {
        const arena = self.arena.allocator();
        self.diagnostic = .{ .part = .styles };
        var custom: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
        var list: std.ArrayList(Format) = .empty;
        var in_cell_xfs = false;
        const part = try PartReader.create(self, entry);
        defer part.destroy();
        while (true) {
            switch (try part.next()) {
                .start => |name| {
                    if (std.mem.eql(u8, name, "numFmt")) {
                        const id = std.fmt.parseInt(u32, part.parser.attribute("numFmtId") orelse return error.InvalidFile, 10) catch return error.InvalidFile;
                        const code = part.parser.attribute("formatCode") orelse return error.InvalidFile;
                        try custom.put(arena, id, try arena.dupe(u8, code));
                    } else if (std.mem.eql(u8, name, "cellXfs")) {
                        in_cell_xfs = true;
                    } else if (in_cell_xfs and std.mem.eql(u8, name, "xf")) {
                        const id = std.fmt.parseInt(u32, part.parser.attribute("numFmtId") orelse "0", 10) catch return error.InvalidFile;
                        const code = custom.get(id) orelse builtinFormat(id);
                        try list.append(arena, .{ .code = code, .kind = classifyFormat(code) });
                    }
                },
                .end => |name| if (std.mem.eql(u8, name, "cellXfs")) {
                    in_cell_xfs = false;
                },
                .eof => break,
                .text => {},
            }
        }
        self.formats = list.items;
    }

    /// Loads the shared strings, once. Each string is the text of its
    /// `<t>` elements put together, without the phonetic ones.
    fn loadStrings(self: *Reader) Error!void {
        if (self.strings_loaded) return;
        self.strings_loaded = true;
        const entry = self.strings_part orelse return;
        self.diagnostic = .{ .part = .shared_strings };
        errdefer self.strings_loaded = false;
        const gpa = self.gpa;
        const part = try PartReader.create(self, entry);
        defer part.destroy();
        var string_start: usize = 0;
        var in_string = false;
        var in_text = false;
        while (true) {
            switch (try part.next()) {
                .start => |name| {
                    if (std.mem.eql(u8, name, "si")) {
                        in_string = true;
                        string_start = self.string_data.items.len;
                    } else if (in_string and std.mem.eql(u8, name, "rPh")) {
                        try part.skip();
                    } else if (in_string and std.mem.eql(u8, name, "t")) {
                        in_text = true;
                    }
                },
                .text => |text| if (in_text) {
                    // The count the file announces is never trusted:
                    // memory grows only with what is really there.
                    if (self.string_data.items.len + text.len + 4 * (self.string_ends.items.len + 1) > self.limits.max_shared_strings_bytes) {
                        return self.exceeded(.shared_strings_bytes);
                    }
                    try self.string_data.appendSlice(gpa, text);
                },
                .end => |name| {
                    if (std.mem.eql(u8, name, "t")) {
                        in_text = false;
                    } else if (std.mem.eql(u8, name, "si")) {
                        in_string = false;
                        const decoded = unescapeCellText(self.string_data.items[string_start..]);
                        if (utf16Len(decoded) > self.limits.max_cell_text) return self.exceeded(.cell_text);
                        self.string_data.shrinkRetainingCapacity(string_start + decoded.len);
                        if (self.string_data.items.len > std.math.maxInt(u32)) return self.exceeded(.shared_strings_bytes);
                        if (4 * (self.string_ends.items.len + 1) + self.string_data.items.len > self.limits.max_shared_strings_bytes) {
                            return self.exceeded(.shared_strings_bytes);
                        }
                        try self.string_ends.append(gpa, @intCast(self.string_data.items.len));
                    }
                },
                .eof => break,
            }
        }
    }

    fn sharedString(self: *const Reader, index: usize) ?[]const u8 {
        if (index >= self.string_ends.items.len) return null;
        const from: usize = if (index == 0) 0 else self.string_ends.items[index - 1];
        return self.string_data.items[from..self.string_ends.items[index]];
    }
};

/// A part being parsed: its zip stream feeding an XML parser.
const PartReader = struct {
    reader: *Reader,
    stream: *zip_reader.Stream,
    parser: xml_reader.Parser,
    /// Why the stream failed, when it did.
    failure: ?zip_reader.Error = null,

    fn create(reader: *Reader, entry: *const zip_reader.Entry) Error!*PartReader {
        const gpa = reader.gpa;
        const self = try gpa.create(PartReader);
        errdefer gpa.destroy(self);
        const stream = try reader.archive.openStream(gpa, entry);
        errdefer stream.deinit();
        self.* = .{
            .reader = reader,
            .stream = stream,
            .parser = xml_reader.Parser.init(gpa, .{ .ptr = self, .readFn = read }, reader.limits.xml) catch return error.OutOfMemory,
        };
        return self;
    }

    fn destroy(self: *PartReader) void {
        const gpa = self.reader.gpa;
        self.parser.deinit();
        self.stream.deinit();
        gpa.destroy(self);
    }

    fn read(ptr: *anyopaque, dest: []u8) xml_reader.Source.Error!usize {
        const self: *PartReader = @ptrCast(@alignCast(ptr));
        return self.stream.read(dest) catch |err| {
            self.failure = err;
            return error.ReadFailed;
        };
    }

    fn fail(self: *PartReader, err: xml_reader.Error) Error {
        self.reader.diagnostic.byte_offset = self.parser.offset();
        return switch (err) {
            error.ReadFailed => self.failure orelse error.InvalidZip,
            error.LimitExceeded => self.reader.exceeded(.xml),
            error.InvalidXml => error.InvalidXml,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn next(self: *PartReader) Error!xml_reader.Event {
        return self.parser.next() catch |err| self.fail(err);
    }

    fn skip(self: *PartReader) Error!void {
        return self.parser.skip() catch |err| self.fail(err);
    }
};

/// The rows of one sheet, read as they are asked for.
pub const Rows = struct {
    reader: *Reader,
    sheet: usize,
    part: *PartReader,
    options: Options,
    /// Reset for every row: texts and formulas of the row's cells.
    row_arena: std.heap.ArenaAllocator,
    cells: std.ArrayList(Cell) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    formula_scratch: std.ArrayList(u8) = .empty,
    merges: std.ArrayList(Range) = .empty,
    /// First cell of each shared formula, for the cells that reuse it.
    masters: std.AutoHashMapUnmanaged(u32, SharedFormula) = .empty,
    masters_arena: std.heap.ArenaAllocator,
    in_sheet_data: bool = false,
    finished: bool = false,
    last_row: ?u32 = null,
    rows_read: u32 = 0,

    const SharedFormula = struct { text: []const u8, row: u32, column: u32 };

    fn create(reader: *Reader, sheet: usize, entry: *const zip_reader.Entry, options: Options) Error!*Rows {
        const gpa = reader.gpa;
        const self = try gpa.create(Rows);
        errdefer gpa.destroy(self);
        self.* = .{
            .reader = reader,
            .sheet = sheet,
            .part = try PartReader.create(reader, entry),
            .options = options,
            .row_arena = .init(gpa),
            .masters_arena = .init(gpa),
        };
        return self;
    }

    pub fn deinit(self: *Rows) void {
        const gpa = self.reader.gpa;
        self.part.destroy();
        self.row_arena.deinit();
        self.masters_arena.deinit();
        self.cells.deinit(gpa);
        self.scratch.deinit(gpa);
        self.formula_scratch.deinit(gpa);
        self.merges.deinit(gpa);
        self.masters.deinit(gpa);
        gpa.destroy(self);
    }

    /// The merged ranges of the sheet. They come after the rows in the
    /// file, so the list is complete only once `next` has returned null.
    pub fn mergedRanges(self: *const Rows) []const Range {
        return self.merges.items;
    }

    /// The next row that exists in the file, or null after the last.
    /// After an error the iterator is finished.
    pub fn next(self: *Rows) Error!?Row {
        if (self.finished) return null;
        const reader = self.reader;
        reader.diagnostic = .{ .part = .sheet, .sheet = self.sheet, .row = self.last_row };
        return self.advance() catch |err| {
            self.finished = true;
            if (reader.diagnostic.byte_offset == null) reader.diagnostic.byte_offset = self.part.parser.offset();
            return err;
        };
    }

    fn advance(self: *Rows) Error!?Row {
        const reader = self.reader;
        while (true) {
            switch (try self.part.next()) {
                .start => |name| {
                    if (self.in_sheet_data) {
                        if (std.mem.eql(u8, name, "row")) return try self.readRow();
                        try self.part.skip();
                    } else if (std.mem.eql(u8, name, "sheetData")) {
                        self.in_sheet_data = true;
                    } else if (std.mem.eql(u8, name, "mergeCell")) {
                        const ref = self.part.parser.attribute("ref") orelse return error.InvalidFile;
                        if (parseRange(ref)) |range| {
                            if (self.merges.items.len >= reader.limits.max_merged_ranges) return reader.exceeded(.merged_ranges);
                            try self.merges.append(reader.gpa, range);
                        } else return error.InvalidFile;
                    }
                },
                .end => |name| if (std.mem.eql(u8, name, "sheetData")) {
                    self.in_sheet_data = false;
                },
                .text => {},
                .eof => {
                    self.finished = true;
                    return null;
                },
            }
        }
    }

    /// Called at a `<row>`: reads its cells up to `</row>`.
    fn readRow(self: *Rows) Error!Row {
        const reader = self.reader;
        const parser = &self.part.parser;

        const number: u32 = if (parser.attribute("r")) |r| number: {
            const one_based = parseRowNumber(r) orelse return error.InvalidFile;
            if (one_based > cell_ref.max_rows) return reader.exceeded(.rows);
            break :number @intCast(one_based - 1);
        } else if (self.last_row) |last| last + 1 else 0;
        if (number >= cell_ref.max_rows) return reader.exceeded(.rows);
        if (self.last_row) |last| {
            if (number <= last) return error.InvalidFile; // rows must come in order
        }
        reader.diagnostic.row = number;
        self.rows_read += 1;
        if (self.rows_read > reader.limits.max_rows) return reader.exceeded(.rows);
        self.last_row = number;
        const hidden = if (parser.attribute("hidden")) |h| std.mem.eql(u8, h, "1") or std.mem.eql(u8, h, "true") else false;

        _ = self.row_arena.reset(.retain_capacity);
        self.cells.clearRetainingCapacity();
        var last_column: ?u32 = null;
        while (true) {
            switch (try self.part.next()) {
                .start => |name| {
                    if (!std.mem.eql(u8, name, "c")) {
                        try self.part.skip();
                        continue;
                    }
                    const column: u32 = if (parser.attribute("r")) |ref| column: {
                        const parsed = parseCellRef(ref) orelse return error.InvalidFile;
                        if (parsed.column == null) return reader.exceeded(.columns);
                        if (parsed.row == null) return reader.exceeded(.rows);
                        if (parsed.row.? != number + 1) return error.InvalidFile;
                        break :column parsed.column.?;
                    } else if (last_column) |last| last + 1 else 0;
                    if (column >= reader.limits.max_columns or column >= cell_ref.max_cols) return reader.exceeded(.columns);
                    if (last_column) |last| {
                        if (column <= last) return error.InvalidFile; // cells must come in order
                    }
                    last_column = column;
                    reader.diagnostic.column = column;
                    try self.cells.append(reader.gpa, try self.readCell(number, column));
                },
                .end => break,
                .text => {},
                .eof => return error.InvalidXml,
            }
        }
        reader.diagnostic.column = null;
        return .{ .number = number, .hidden = hidden, .cells = self.cells.items };
    }

    const CellType = enum { number, shared, inline_text, formula_text, boolean, err, iso_date };

    /// Called at a `<c>`: reads its children up to `</c>`.
    fn readCell(self: *Rows, row: u32, column: u32) Error!Cell {
        const reader = self.reader;
        const parser = &self.part.parser;
        const arena = self.row_arena.allocator();

        const cell_type: CellType = if (parser.attribute("t")) |t|
            if (std.mem.eql(u8, t, "s")) .shared else if (std.mem.eql(u8, t, "inlineStr")) .inline_text else if (std.mem.eql(u8, t, "str")) .formula_text else if (std.mem.eql(u8, t, "b")) .boolean else if (std.mem.eql(u8, t, "e")) .err else if (std.mem.eql(u8, t, "d")) .iso_date else if (std.mem.eql(u8, t, "n")) .number else return error.InvalidFile
        else
            .number;
        const format: Format = if (parser.attribute("s")) |s| format: {
            const index = std.fmt.parseInt(u32, s, 10) catch return error.InvalidFile;
            break :format if (index < reader.formats.len) reader.formats[index] else general;
        } else if (reader.formats.len > 0) reader.formats[0] else general;

        self.scratch.clearRetainingCapacity();
        var has_value = false;
        var formula: ?[]const u8 = null;
        while (true) {
            switch (try self.part.next()) {
                .start => |name| {
                    if (std.mem.eql(u8, name, "v")) {
                        has_value = true;
                        try self.collectText(&self.scratch);
                    } else if (std.mem.eql(u8, name, "is")) {
                        has_value = true;
                        try self.collectRichText(&self.scratch);
                    } else if (std.mem.eql(u8, name, "f") and self.options.formulas) {
                        formula = try self.readFormula(row, column);
                    } else try self.part.skip();
                },
                .end => break,
                .text => {},
                .eof => return error.InvalidXml,
            }
        }

        const raw = self.scratch.items;
        const value: Value = if (!has_value) .empty else switch (cell_type) {
            .shared => value: {
                const index = std.fmt.parseInt(usize, std.mem.trim(u8, raw, " \t\r\n"), 10) catch return error.InvalidFile;
                break :value .{ .text = reader.sharedString(index) orelse return error.InvalidFile };
            },
            .inline_text, .formula_text => .{ .text = try self.ownText(raw) },
            .err => .{ .err = try self.ownText(raw) },
            .boolean => value: {
                const text = std.mem.trim(u8, raw, " \t\r\n");
                if (std.mem.eql(u8, text, "1") or std.mem.eql(u8, text, "true")) break :value .{ .boolean = true };
                if (std.mem.eql(u8, text, "0") or std.mem.eql(u8, text, "false")) break :value .{ .boolean = false };
                return error.InvalidFile;
            },
            .iso_date => if (parseIsoDate(std.mem.trim(u8, raw, " \t\r\n"))) |dt| .{ .date = dt } else .{ .text = try self.ownText(raw) },
            .number => value: {
                const text = std.mem.trim(u8, raw, " \t\r\n");
                if (text.len == 0) break :value .empty;
                const number = std.fmt.parseFloat(f64, text) catch return error.InvalidFile;
                if (!std.math.isFinite(number)) return error.InvalidFile;
                break :value switch (format.kind) {
                    .number, .duration => .{ .number = number },
                    .date => if (date_mod.fromSerial(number, reader.date_system)) |dt| .{ .date = dt } else .{ .number = number },
                    .time => if (number >= 0 and number < 1)
                        .{ .time = .fromFraction(number) }
                    else if (date_mod.fromSerial(number, reader.date_system)) |dt| .{ .date = dt } else .{ .number = number },
                };
            },
        };
        _ = arena;
        return .{ .column = column, .value = value, .format = format.code, .formula = formula };
    }

    /// Copies text into the row's arena, undoing the `_xHHHH_` escapes,
    /// and checks its length.
    fn ownText(self: *Rows, raw: []const u8) Error![]const u8 {
        const copy = try self.row_arena.allocator().dupe(u8, raw);
        const decoded = unescapeCellText(copy);
        if (utf16Len(decoded) > self.reader.limits.max_cell_text) return self.reader.exceeded(.cell_text);
        return decoded;
    }

    /// Bytes a cell's text may take before its length is even counted.
    fn textBudget(self: *const Rows) usize {
        return @as(usize, self.reader.limits.max_cell_text) * 8 + 64;
    }

    /// Called inside an element that holds only text (`<v>`, `<t>`,
    /// `<f>`): appends it to `out`, up to the closing tag.
    fn collectText(self: *Rows, out: *std.ArrayList(u8)) Error!void {
        while (true) {
            switch (try self.part.next()) {
                .text => |text| {
                    if (out.items.len + text.len > self.textBudget()) return self.reader.exceeded(.cell_text);
                    try out.appendSlice(self.reader.gpa, text);
                },
                .start => try self.part.skip(),
                .end => return,
                .eof => return error.InvalidXml,
            }
        }
    }

    /// Called inside `<is>`: the text of every `<t>`, except phonetic
    /// ones, in order.
    fn collectRichText(self: *Rows, out: *std.ArrayList(u8)) Error!void {
        var open: usize = 1;
        while (open > 0) {
            switch (try self.part.next()) {
                .start => |name| {
                    if (std.mem.eql(u8, name, "t")) {
                        try self.collectText(out);
                    } else if (std.mem.eql(u8, name, "rPh") or std.mem.eql(u8, name, "rPr")) {
                        try self.part.skip();
                    } else open += 1;
                },
                .end => open -= 1,
                .text => {},
                .eof => return error.InvalidXml,
            }
        }
    }

    /// Called at an `<f>`: the formula's text. A cell that reuses a
    /// shared formula gets the first cell's text moved to its position.
    fn readFormula(self: *Rows, row: u32, column: u32) Error!?[]const u8 {
        const reader = self.reader;
        const parser = &self.part.parser;
        const shared = if (parser.attribute("t")) |t| std.mem.eql(u8, t, "shared") else false;
        const group: ?u32 = if (shared) std.fmt.parseInt(u32, parser.attribute("si") orelse return error.InvalidFile, 10) catch return error.InvalidFile else null;

        self.formula_scratch.clearRetainingCapacity();
        try self.collectText(&self.formula_scratch);
        const text = self.formula_scratch.items;
        const arena = self.row_arena.allocator();
        if (text.len > 0) {
            if (group) |si| {
                const kept = try self.masters_arena.allocator().dupe(u8, text);
                try self.masters.put(reader.gpa, si, .{ .text = kept, .row = row, .column = column });
            }
            return try arena.dupe(u8, text);
        }
        if (group) |si| {
            const master = self.masters.get(si) orelse return error.InvalidFile;
            return try shiftFormula(arena, master.text, @as(i64, row) - master.row, @as(i64, column) - master.column);
        }
        return null;
    }
};

/// Joins a relationship target to the directory of the part that
/// declares it, and resolves `.` and `..`.
fn resolvePath(arena: std.mem.Allocator, directory: []const u8, target: []const u8) Error![]const u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    const absolute = std.mem.startsWith(u8, target, "/");
    if (!absolute) {
        var base = std.mem.splitScalar(u8, directory, '/');
        while (base.next()) |segment| {
            if (segment.len > 0) try segments.append(arena, segment);
        }
    }
    var parts = std.mem.splitScalar(u8, target, '/');
    while (parts.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (segments.items.len == 0) return error.InvalidFile; // out of the package
            _ = segments.pop();
        } else try segments.append(arena, segment);
    }
    return std.mem.join(arena, "/", segments.items);
}

/// The one-based row number of a `<row r="…">`: digits only, not zero.
/// Numbers too long to matter come back as a value past any limit.
fn parseRowNumber(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    if (text.len > 9) return std.math.maxInt(u64);
    const value = std.fmt.parseInt(u64, text, 10) catch return null;
    return if (value == 0) null else value;
}

const CellRef = struct {
    /// Zero-based; null when it is past the last possible column.
    column: ?u32,
    /// One-based; null when it is past the last possible row.
    row: ?u64,
};

/// Parses `B7` (also `$B$7`). Null when it is not a reference at all.
fn parseCellRef(text: []const u8) ?CellRef {
    var i: usize = 0;
    if (i < text.len and text[i] == '$') i += 1;
    const letters_start = i;
    while (i < text.len and std.ascii.isAlphabetic(text[i])) i += 1;
    const letters = text[letters_start..i];
    if (letters.len == 0) return null;
    if (i < text.len and text[i] == '$') i += 1;
    const digits = text[i..];
    const row = parseRowNumber(digits) orelse return null;

    var column: ?u32 = null;
    if (letters.len <= 3) {
        var value: u32 = 0;
        for (letters) |c| value = value * 26 + (std.ascii.toUpper(c) - 'A' + 1);
        if (value <= cell_ref.max_cols) column = value - 1;
    }
    return .{ .column = column, .row = if (row > cell_ref.max_rows) null else row };
}

/// Parses `A1:C3` into a range. Null for anything else.
fn parseRange(text: []const u8) ?Range {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    const first = parseCellRef(text[0..colon]) orelse return null;
    const last = parseCellRef(text[colon + 1 ..]) orelse return null;
    if (first.column == null or last.column == null or first.row == null or last.row == null) return null;
    if (last.row.? < first.row.? or last.column.? < first.column.?) return null;
    return .{
        .first_row = @intCast(first.row.? - 1),
        .first_col = first.column.?,
        .last_row = @intCast(last.row.? - 1),
        .last_col = last.column.?,
    };
}

/// Moves the relative references of a formula by a number of rows and
/// columns, the way a spreadsheet fills a formula down or across.
/// Text between double quotes and absolute (`$`) parts are left alone.
fn shiftFormula(arena: std.mem.Allocator, formula: []const u8, rows: i64, columns: i64) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < formula.len) {
        const c = formula[i];
        if (c == '"') {
            // A string constant, with "" for a quote inside it.
            const from = i;
            i += 1;
            while (i < formula.len) : (i += 1) {
                if (formula[i] == '"') {
                    if (i + 1 < formula.len and formula[i + 1] == '"') {
                        i += 1;
                    } else break;
                }
            }
            i = @min(i + 1, formula.len);
            try out.appendSlice(arena, formula[from..i]);
            continue;
        }
        if (c == '\'') {
            // A quoted sheet name.
            const close = std.mem.indexOfScalarPos(u8, formula, i + 1, '\'') orelse formula.len - 1;
            try out.appendSlice(arena, formula[i .. close + 1]);
            i = close + 1;
            continue;
        }
        const starts_token = i == 0 or !(std.ascii.isAlphanumeric(formula[i - 1]) or formula[i - 1] == '_' or formula[i - 1] == '.');
        if (starts_token and (c == '$' or std.ascii.isAlphabetic(c))) {
            if (matchReference(formula[i..])) |ref| {
                const next_char: u8 = if (i + ref.len < formula.len) formula[i + ref.len] else 0;
                // `LOG10(` is a function and `A1B` a name, not references.
                if (!(std.ascii.isAlphanumeric(next_char) or next_char == '_' or next_char == '(' or next_char == '.')) {
                    const new_column = if (ref.column_absolute) @as(i64, ref.column) else @as(i64, ref.column) + columns;
                    const new_row = if (ref.row_absolute) @as(i64, ref.row) else @as(i64, ref.row) + rows;
                    if (new_column >= 0 and new_column < cell_ref.max_cols and new_row >= 1 and new_row <= cell_ref.max_rows) {
                        if (ref.column_absolute) try out.append(arena, '$');
                        var letters: [3]u8 = undefined;
                        var n: u32 = @intCast(new_column + 1);
                        var at: usize = letters.len;
                        while (n > 0) {
                            n -= 1;
                            at -= 1;
                            letters[at] = 'A' + @as(u8, @intCast(n % 26));
                            n /= 26;
                        }
                        try out.appendSlice(arena, letters[at..]);
                        if (ref.row_absolute) try out.append(arena, '$');
                        var digits: [10]u8 = undefined;
                        try out.appendSlice(arena, std.fmt.bufPrint(&digits, "{d}", .{new_row}) catch unreachable);
                    } else try out.appendSlice(arena, "#REF!");
                    i += ref.len;
                    continue;
                }
            }
            // Not a reference: copy the whole word, so its tail is not
            // taken for one.
            const from = i;
            while (i < formula.len and (std.ascii.isAlphanumeric(formula[i]) or formula[i] == '_' or formula[i] == '$' or formula[i] == '.')) i += 1;
            if (i == from) i += 1;
            try out.appendSlice(arena, formula[from..i]);
            continue;
        }
        try out.append(arena, c);
        i += 1;
    }
    return out.items;
}

const MatchedReference = struct { len: usize, column: u32, row: u32, column_absolute: bool, row_absolute: bool };

/// Matches `A1`, `$A1`, `A$1` or `$A$1` at the start of `text`.
fn matchReference(text: []const u8) ?MatchedReference {
    var i: usize = 0;
    const column_absolute = i < text.len and text[i] == '$';
    if (column_absolute) i += 1;
    const letters_start = i;
    while (i < text.len and i - letters_start < 3 and text[i] >= 'A' and text[i] <= 'Z') i += 1;
    if (i == letters_start) return null;
    var column: u32 = 0;
    for (text[letters_start..i]) |c| column = column * 26 + (c - 'A' + 1);
    if (column > cell_ref.max_cols) return null;
    const row_absolute = i < text.len and text[i] == '$';
    if (row_absolute) i += 1;
    const digits_start = i;
    while (i < text.len and i - digits_start < 7 and std.ascii.isDigit(text[i])) i += 1;
    if (i == digits_start or text[digits_start] == '0') return null;
    const row = std.fmt.parseInt(u32, text[digits_start..i], 10) catch return null;
    if (row > cell_ref.max_rows) return null;
    return .{ .len = i, .column = column - 1, .row = row, .column_absolute = column_absolute, .row_absolute = row_absolute };
}

/// `2026-10-07`, `2026-10-07T13:01:01`, with an optional fraction and
/// zone suffix, which are ignored.
fn parseIsoDate(text: []const u8) ?DateTime {
    if (text.len < 10 or text[4] != '-' or text[7] != '-') return null;
    var dt: DateTime = .{
        .year = std.fmt.parseInt(u16, text[0..4], 10) catch return null,
        .month = std.fmt.parseInt(u8, text[5..7], 10) catch return null,
        .day = std.fmt.parseInt(u8, text[8..10], 10) catch return null,
    };
    if (text.len >= 19 and (text[10] == 'T' or text[10] == ' ') and text[13] == ':' and text[16] == ':') {
        dt.hour = std.fmt.parseInt(u8, text[11..13], 10) catch return null;
        dt.minute = std.fmt.parseInt(u8, text[14..16], 10) catch return null;
        dt.second = std.fmt.parseInt(u8, text[17..19], 10) catch return null;
    } else if (text.len != 10) return null;
    // Only real dates and times.
    _ = dt.serial() catch return null;
    return dt;
}

/// Undoes, in place, the `_xHHHH_` notation cell text uses for
/// characters XML cannot carry, and returns the shorter slice.
fn unescapeCellText(text: []u8) []u8 {
    if (std.mem.indexOf(u8, text, "_x") == null) return text;
    var out: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '_' and i + 6 < text.len and text[i + 1] == 'x' and text[i + 6] == '_') {
            if (std.fmt.parseInt(u16, text[i + 2 .. i + 6], 16)) |unit| {
                // Surrogates cannot stand alone: leave them as written.
                if (unit < 0xD800 or unit > 0xDFFF) {
                    var encoded: [3]u8 = undefined;
                    const len = std.unicode.utf8Encode(unit, &encoded) catch unreachable;
                    @memcpy(text[out..][0..len], encoded[0..len]);
                    out += len;
                    i += 7;
                    continue;
                }
            } else |_| {}
        }
        text[out] = text[i];
        out += 1;
        i += 1;
    }
    return text[0..out];
}

/// Length in UTF-16 code units of valid UTF-8: how Excel counts.
fn utf16Len(text: []const u8) usize {
    var len: usize = 0;
    for (text) |byte| {
        if (byte & 0xc0 != 0x80) len += 1;
        if (byte >= 0xf0) len += 1;
    }
    return len;
}

/// The format codes every program has built in. Ids not listed are
/// locale-specific or unused; they read as `General`.
fn builtinFormat(id: u32) []const u8 {
    return switch (id) {
        1 => "0",
        2 => "0.00",
        3 => "#,##0",
        4 => "#,##0.00",
        9 => "0%",
        10 => "0.00%",
        11 => "0.00E+00",
        12 => "# ?/?",
        13 => "# ??/??",
        14 => "mm-dd-yy",
        15 => "d-mmm-yy",
        16 => "d-mmm",
        17 => "mmm-yy",
        18 => "h:mm AM/PM",
        19 => "h:mm:ss AM/PM",
        20 => "h:mm",
        21 => "h:mm:ss",
        22 => "m/d/yy h:mm",
        // Dates in East Asian locales.
        27...36, 50...58 => "yyyy/m/d",
        37 => "#,##0 ;(#,##0)",
        38 => "#,##0 ;[Red](#,##0)",
        39 => "#,##0.00;(#,##0.00)",
        40 => "#,##0.00;[Red](#,##0.00)",
        45 => "mm:ss",
        46 => "[h]:mm:ss",
        47 => "mmss.0",
        48 => "##0.0E+0",
        49 => "@",
        else => "General",
    };
}

/// Decides whether a number format shows a date, a time of day, an
/// elapsed time or a plain number, from its first section.
fn classifyFormat(code: []const u8) NumberKind {
    var has_date = false; // d, y
    var has_month_or_minute = false; // m
    var has_time = false; // h, s, AM/PM
    var i: usize = 0;
    while (i < code.len) : (i += 1) {
        switch (code[i]) {
            ';' => break,
            '"' => i = std.mem.indexOfScalarPos(u8, code, i + 1, '"') orelse code.len,
            '\\', '_', '*' => i += 1,
            '[' => {
                const close = std.mem.indexOfScalarPos(u8, code, i + 1, ']') orelse code.len;
                const inside = code[@min(i + 1, code.len)..close];
                // [h], [mm], [ss]: elapsed time. Colours, locales and
                // conditions are skipped.
                if (inside.len > 0) {
                    const first = std.ascii.toLower(inside[0]);
                    const same = for (inside) |c| {
                        if (std.ascii.toLower(c) != first) break false;
                    } else true;
                    if (same and (first == 'h' or first == 'm' or first == 's')) return .duration;
                }
                i = close;
            },
            'd', 'D', 'y', 'Y' => has_date = true,
            'm', 'M' => has_month_or_minute = true,
            'h', 'H', 's', 'S' => has_time = true,
            'a', 'A' => if (std.ascii.startsWithIgnoreCase(code[i..], "am/pm") or std.ascii.startsWithIgnoreCase(code[i..], "a/p")) {
                has_time = true;
            },
            // "General" and "Standard" are words, not format letters.
            'G', 'g' => if (std.ascii.startsWithIgnoreCase(code[i..], "general")) {
                i += 6;
            },
            else => {},
        }
    }
    if (has_date or (has_month_or_minute and !has_time)) return .date;
    if (has_time) return .time;
    return .number;
}

const testing = std.testing;
const writer_mod = @import("workbook.zig");

const ns = "xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"";
const rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
const root_rels = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" ++
    "<Relationship Id=\"rId1\" Type=\"" ++ rel ++ "/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>";
const one_sheet_workbook = "<workbook " ++ ns ++ "><sheets><sheet name=\"Dados\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>";
const one_sheet_rels = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" ++
    "<Relationship Id=\"rId1\" Type=\"" ++ rel ++ "/worksheet\" Target=\"worksheets/sheet1.xml\"/>" ++
    "<Relationship Id=\"rId2\" Type=\"" ++ rel ++ "/styles\" Target=\"styles.xml\"/>" ++
    "<Relationship Id=\"rId3\" Type=\"" ++ rel ++ "/sharedStrings\" Target=\"sharedStrings.xml\"/></Relationships>";

/// Packs named parts into a stored zip.
fn package(parts: []const [2][]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    var store: zip_writer.StoreZip = .init(testing.allocator, &out.writer);
    defer store.deinit();
    for (parts) |part| try store.addPart(part[0], part[1]);
    try store.finish();
    return out.toOwnedSlice();
}

const Hand = struct {
    sheet: []const u8,
    strings: ?[]const u8 = null,
    styles: ?[]const u8 = null,
    workbook: []const u8 = one_sheet_workbook,
};

/// A one-sheet package written by hand, the way another program might.
fn handmade(hand: Hand) ![]u8 {
    var parts: [6][2][]const u8 = undefined;
    var n: usize = 0;
    parts[n] = .{ "_rels/.rels", root_rels };
    n += 1;
    parts[n] = .{ "xl/workbook.xml", hand.workbook };
    n += 1;
    parts[n] = .{ "xl/_rels/workbook.xml.rels", one_sheet_rels };
    n += 1;
    parts[n] = .{ "xl/worksheets/sheet1.xml", hand.sheet };
    n += 1;
    if (hand.strings) |strings| {
        parts[n] = .{ "xl/sharedStrings.xml", strings };
        n += 1;
    }
    if (hand.styles) |styles| {
        parts[n] = .{ "xl/styles.xml", styles };
        n += 1;
    }
    return package(parts[0..n]);
}

/// Reads the first sheet and writes one line per row: `row: col=value …`.
fn dump(gpa: std.mem.Allocator, bytes: []const u8, limits: Limits, options: Options) ![]u8 {
    const book = try Reader.open(gpa, bytes, limits);
    defer book.deinit();
    const rows = try book.rows(0, options);
    defer rows.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    while (try rows.next()) |row| {
        w.print("{d}{s}:", .{ row.number, if (row.hidden) "h" else "" }) catch return error.OutOfMemory;
        for (row.cells) |cell| {
            w.print(" {d}=", .{cell.column}) catch return error.OutOfMemory;
            (switch (cell.value) {
                .empty => w.writeAll("_"),
                .text => |t| w.print("'{s}'", .{t}),
                .number => |n| w.print("{d}", .{n}),
                .boolean => |b| w.print("{}", .{b}),
                .date => |d| w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ d.year, d.month, d.day, d.hour, d.minute, d.second }),
                .time => |t| w.print("T{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second }),
                .err => |e| w.print("!{s}", .{e}),
            }) catch return error.OutOfMemory;
            if (cell.formula) |f| w.print("[={s}]", .{f}) catch return error.OutOfMemory;
        }
        w.writeByte('\n') catch return error.OutOfMemory;
    }
    for (rows.mergedRanges()) |m| w.print("merge {d},{d}-{d},{d}\n", .{ m.first_row, m.first_col, m.last_row, m.last_col }) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn expectDump(expected: []const u8, hand: Hand) !void {
    const bytes = try handmade(hand);
    defer testing.allocator.free(bytes);
    const got = try dump(testing.allocator, bytes, .{}, .{});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

fn expectHandError(expected: Error, hand: Hand, limits: Limits) !void {
    const bytes = try handmade(hand);
    defer testing.allocator.free(bytes);
    try testing.expectError(expected, dump(testing.allocator, bytes, limits, .{}));
}

test "round trip: what the writer writes, the reader reads" {
    const wb = try writer_mod.Workbook.init(testing.allocator);
    defer wb.deinit();
    const first = try wb.addSheet("Resultado");
    try first.setRow(0, 0, &.{ .{ .text = "Opção" }, .{ .text = "Votos" }, .{ .text = "%" } }, .{ .bold = true, .fill = 0xDDEEFF });
    try first.set(1, 0, .{ .text = " Sim\n(duas linhas) " });
    try first.set(1, 1, .int(12));
    try first.setStyled(1, 2, .{ .number = 0.75 }, .{ .number_format = .percent });
    try first.set(2, 0, .{ .text = "_x000D_ literal & <tag> \x01 control\r" });
    try first.set(2, 1, .{ .number = -1234.5 });
    try first.set(2, 2, .{ .boolean = true });
    try first.set(2, 3, .{ .boolean = false });
    try first.set(4, 0, .{ .date = .{ .year = 2026, .month = 10, .day = 7 } });
    try first.set(4, 1, .{ .datetime = .{ .year = 2026, .month = 10, .day = 7, .hour = 13, .minute = 1, .second = 1 } });
    try first.setStyled(4, 2, .{ .date = .{ .year = 1900, .month = 3, .day = 1 } }, .{ .number_format = .{ .custom = "dd/mm/yyyy" } });
    try first.setStyled(4, 3, .{ .datetime = .{ .year = 1900, .month = 1, .day = 1, .hour = 9, .minute = 30 } }, .{ .number_format = .time });
    try first.setStyled(4, 4, .int(12345678901), .{ .number_format = .{ .custom = "00000000000" } });
    try first.set(5, 0, .{ .formula = "SUM(B2:B3)" });
    try first.setStyled(6, 1, .blank, .{ .border = .thin });
    try first.set(6, 2, .{ .text = "=1+1" });
    try first.hideRow(6);
    try first.mergeCells(.{ .first_row = 8, .first_col = 0, .last_row = 9, .last_col = 2 });
    const second = try wb.addSheet("Vazia");
    _ = second;
    const third = try wb.addSheet("Só títulos");
    try third.set(0, 0, .{ .text = "Opção" });
    const bytes = try wb.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(bytes);

    const book = try Reader.open(testing.allocator, bytes, .{});
    defer book.deinit();
    try testing.expectEqual(@as(usize, 3), book.sheets().len);
    try testing.expectEqualStrings("Resultado", book.sheets()[0].name);
    try testing.expectEqualStrings("Só títulos", book.sheets()[2].name);
    try testing.expectEqual(Visibility.visible, book.sheets()[1].visibility);
    try testing.expectEqual(@as(?usize, 2), book.sheetIndex("só títulos"));
    try testing.expectEqual(@as(?usize, 0), book.sheetIndex("RESULTADO"));
    try testing.expectEqual(@as(?usize, null), book.sheetIndex("Outra"));

    const got = try dump(testing.allocator, bytes, .{}, .{ .formulas = true });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\0: 0='Opção' 1='Votos' 2='%'
        \\1: 0=' Sim
        \\(duas linhas) ' 1=12 2=0.75
    ++ "\n2: 0='_x000D_ literal & <tag> \x01 control\r' 1=-1234.5 2=true 3=false\n" ++
        \\4: 0=2026-10-07T00:00:00 1=2026-10-07T13:01:01 2=1900-03-01T00:00:00 3=1900-01-01T09:30:00 4=12345678901
        \\5: 0=_[=SUM(B2:B3)]
        \\6h: 1=_ 2='=1+1'
        \\merge 8,0-9,2
        \\
    , got);

    // The number format comes with each cell.
    const rows = try book.rows(0, .{});
    defer rows.deinit();
    _ = try rows.next();
    const second_row = (try rows.next()).?;
    try testing.expectEqualStrings("General", second_row.cells[1].format);
    try testing.expectEqualStrings("0%", second_row.cells[2].format);
    _ = try rows.next();
    const dates = (try rows.next()).?;
    try testing.expectEqualStrings("dd/mm/yyyy", dates.cells[2].format);
    try testing.expectEqualStrings("00000000000", dates.cells[4].format);
    // Formula text is only returned when asked for.
    try testing.expect((try rows.next()).?.cells[0].formula == null);

    // An empty sheet has no rows; a sheet can be read more than once.
    for (0..2) |_| {
        const empty = try book.rows(1, .{});
        defer empty.deinit();
        try testing.expect(try empty.next() == null);
        try testing.expect(try empty.next() == null);
    }
    try testing.expectError(error.SheetNotFound, book.rows(3, .{}));
}

test "other producers: inline strings, prefixes, rich text, missing references, sparse rows" {
    try expectDump(
        \\0: 0='inline' 1='a b c' 2=3.5
        \\1: 0='shared rich' 1='next' 2=_
        \\9: 5='far'
        \\10: 0='auto row' 1='auto col'
        \\
    , .{
        .sheet = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><x:worksheet xmlns:x=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">" ++
            "<x:sheetPr/><x:dimension ref=\"A1:F11\"/><x:cols><x:col min=\"1\" max=\"1\" width=\"9\"/></x:cols><x:sheetData>" ++
            "<x:row r=\"1\"><x:c r=\"A1\" t=\"inlineStr\"><x:is><x:t>inline</x:t></x:is></x:c>" ++
            "<x:c r=\"B1\" t=\"inlineStr\"><x:is><x:r><x:rPr><x:b/></x:rPr><x:t xml:space=\"preserve\">a </x:t></x:r><x:r><x:t>b</x:t></x:r><x:rPh><x:t>IGNORED</x:t></x:rPh><x:r><x:t xml:space=\"preserve\"> c</x:t></x:r></x:is></x:c>" ++
            "<x:c r=\"C1\"><x:v>3.5</x:v></x:c></x:row>" ++
            "<x:row><x:c t=\"s\"><x:v>0</x:v></x:c><x:c t=\"s\"><x:v>1</x:v></x:c><x:c s=\"0\"/></x:row>" ++
            "<x:row r=\"10\"><x:c r=\"F10\" t=\"str\"><x:v>far</x:v></x:c></x:row>" ++
            "<x:row><x:c t=\"str\"><x:v>auto row</x:v></x:c><x:c t=\"str\"><x:v>auto col</x:v></x:c></x:row>" ++
            "</x:sheetData><x:pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/></x:worksheet>",
        .strings = "<sst " ++ ns ++ " count=\"2\" uniqueCount=\"2\"><si><r><t>shared </t></r><r><rPr><i/></rPr><t>rich</t></r><rPh sb=\"0\" eb=\"1\"><t>IGNORED</t></rPh><phoneticPr fontId=\"1\"/></si><si><t>next</t></si></sst>",
    });
}

test "formulas: cached values of every type, shared formulas, text only on request" {
    const sheet = "<worksheet " ++ ns ++ "><sheetData>" ++
        "<row r=\"1\"><c r=\"A1\"><f>SUM(B1:C1)</f><v>7</v></c><c r=\"B1\" t=\"str\"><f>\"a\"&amp;\"b\"</f><v>ab</v></c>" ++
        "<c r=\"C1\" t=\"b\"><f>1=1</f><v>1</v></c><c r=\"D1\" t=\"e\"><f>1/0</f><v>#DIV/0!</v></c><c r=\"E1\"><f>NOW()</f></c></row>" ++
        "<row r=\"2\"><c r=\"A2\"><f t=\"shared\" ref=\"A2:A4\" si=\"0\">B2*$C$1+C2</f><v>1</v></c><c r=\"B2\"><f t=\"shared\" ref=\"B2:C2\" si=\"1\">\"A1\"&amp;Plan!A1</f><v>0</v></c><c r=\"C2\"><f t=\"shared\" si=\"1\"/><v>0</v></c></row>" ++
        "<row r=\"3\"><c r=\"A3\"><f t=\"shared\" si=\"0\"/><v>2</v></c></row>" ++
        "<row r=\"4\"><c r=\"A4\"><f t=\"shared\" si=\"0\"/><v>3</v></c><c r=\"B4\"><f t=\"array\" ref=\"B4\">SUM(A2:A4*2)</f><v>12</v></c></row>" ++
        "</sheetData></worksheet>";
    try expectDump(
        \\0: 0=7 1='ab' 2=true 3=!#DIV/0! 4=_
        \\1: 0=1 1=0 2=0
        \\2: 0=2
        \\3: 0=3 1=12
        \\
    , .{ .sheet = sheet });

    const bytes = try handmade(.{ .sheet = sheet });
    defer testing.allocator.free(bytes);
    const got = try dump(testing.allocator, bytes, .{}, .{ .formulas = true });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\0: 0=7[=SUM(B1:C1)] 1='ab'[="a"&"b"] 2=true[=1=1] 3=!#DIV/0![=1/0] 4=_[=NOW()]
        \\1: 0=1[=B2*$C$1+C2] 1=0[="A1"&Plan!A1] 2=0[="A1"&Plan!B1]
        \\2: 0=2[=B3*$C$1+C3]
        \\3: 0=3[=B4*$C$1+C4] 1=12[=SUM(A2:A4*2)]
        \\
    , got);
}

const date_styles = "<styleSheet " ++ ns ++ "><numFmts count=\"4\">" ++
    "<numFmt numFmtId=\"164\" formatCode=\"dd/mm/yyyy\\ hh:mm\"/><numFmt numFmtId=\"165\" formatCode=\"#,##0.00&quot; dias&quot;\"/>" ++
    "<numFmt numFmtId=\"166\" formatCode=\"[h]:mm:ss\"/><numFmt numFmtId=\"167\" formatCode=\"[$-416]d \\d\\e mmmm \\d\\e yyyy;@\"/></numFmts>" ++
    "<cellXfs count=\"8\"><xf numFmtId=\"0\"/><xf numFmtId=\"14\"/><xf numFmtId=\"22\"/><xf numFmtId=\"164\"/>" ++
    "<xf numFmtId=\"165\"/><xf numFmtId=\"20\"/><xf numFmtId=\"166\"/><xf numFmtId=\"167\"/></cellXfs></styleSheet>";

test "dates: by number format, in both date systems, with the 1900 leap-year bug" {
    const cells = "<row r=\"1\"><c r=\"A1\" s=\"1\"><v>1</v></c><c r=\"B1\" s=\"1\"><v>59</v></c><c r=\"C1\" s=\"1\"><v>60</v></c><c r=\"D1\" s=\"1\"><v>61</v></c><c r=\"E1\" s=\"2\"><v>46302.5</v></c></row>" ++
        "<row r=\"2\"><c r=\"A2\" s=\"3\"><v>46302.999994</v></c><c r=\"B2\" s=\"4\"><v>46302</v></c><c r=\"C2\" s=\"5\"><v>0.75</v></c><c r=\"D2\" s=\"6\"><v>1.5</v></c><c r=\"E2\" s=\"7\"><v>45292</v></c></row>" ++
        "<row r=\"3\"><c r=\"A3\" s=\"1\"><v>-1</v></c><c r=\"B3\" s=\"1\"><v>2958466</v></c><c r=\"C3\" s=\"0\"><v>46302</v></c><c r=\"D3\" t=\"d\"><v>2026-10-07T13:01:01Z</v></c><c r=\"E3\" t=\"d\"><v>2026-10-07</v></c></row>";
    // 1900 system. Serial 60 is the day that never existed: it stays a number.
    try expectDump(
        \\0: 0=1900-01-01T00:00:00 1=1900-02-28T00:00:00 2=60 3=1900-03-01T00:00:00 4=2026-10-07T12:00:00
        \\1: 0=2026-10-07T23:59:59 1=46302 2=T18:00:00 3=1.5 4=2024-01-01T00:00:00
        \\2: 0=-1 1=2958466 2=46302 3=2026-10-07T13:01:01 4=2026-10-07T00:00:00
        \\
    , .{ .sheet = "<worksheet " ++ ns ++ "><sheetData>" ++ cells ++ "</sheetData></worksheet>", .styles = date_styles });
    // 1904 system: day 0 is 1904-01-01 and there is no phantom day.
    try expectDump(
        \\0: 0=1904-01-02T00:00:00 1=1904-02-29T00:00:00 2=1904-03-01T00:00:00 3=1904-03-02T00:00:00 4=2030-10-08T12:00:00
        \\1: 0=2030-10-08T23:59:59 1=46302 2=T18:00:00 3=1.5 4=2028-01-02T00:00:00
        \\2: 0=-1 1=2958466 2=46302 3=2026-10-07T13:01:01 4=2026-10-07T00:00:00
        \\
    , .{
        .sheet = "<worksheet " ++ ns ++ "><sheetData>" ++ cells ++ "</sheetData></worksheet>",
        .styles = date_styles,
        .workbook = "<workbook " ++ ns ++ "><workbookPr date1904=\"1\"/><sheets><sheet name=\"Dados\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>",
    });
}

test "sheet list: hidden sheets, chart sheets, lookup, and no shared strings or styles part" {
    const bytes = try package(&.{
        .{ "_rels/.rels", root_rels },
        .{ "xl/workbook.xml", "<workbook " ++ ns ++ "><sheets><sheet name=\"A\" sheetId=\"1\" r:id=\"rId1\"/><sheet name=\"Oculta\" sheetId=\"2\" state=\"hidden\" r:id=\"rId2\"/>" ++
            "<sheet name=\"Muito oculta\" sheetId=\"3\" state=\"veryHidden\" r:id=\"rId3\"/><sheet name=\"Gráfico\" sheetId=\"4\" r:id=\"rId4\"/></sheets></workbook>" },
        .{ "xl/_rels/workbook.xml.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" ++
            "<Relationship Id=\"rId2\" Type=\"" ++ rel ++ "/worksheet\" Target=\"/xl/worksheets/b.xml\"/>" ++
            "<Relationship Id=\"rId1\" Type=\"" ++ rel ++ "/worksheet\" Target=\"worksheets/a.xml\"/>" ++
            "<Relationship Id=\"rId3\" Type=\"" ++ rel ++ "/worksheet\" Target=\"worksheets/../worksheets/c.xml\"/>" ++
            "<Relationship Id=\"rId4\" Type=\"" ++ rel ++ "/chartsheet\" Target=\"chartsheets/sheet1.xml\"/></Relationships>" },
        .{ "xl/worksheets/a.xml", "<worksheet " ++ ns ++ "><sheetData><row><c><v>1</v></c></row></sheetData></worksheet>" },
        .{ "xl/worksheets/b.xml", "<worksheet " ++ ns ++ "><sheetData><row><c><v>2</v></c></row></sheetData></worksheet>" },
        .{ "xl/worksheets/c.xml", "<worksheet " ++ ns ++ "><sheetData/></worksheet>" },
        .{ "xl/chartsheets/sheet1.xml", "<chartsheet/>" },
    });
    defer testing.allocator.free(bytes);
    const book = try Reader.open(testing.allocator, bytes, .{});
    defer book.deinit();
    try testing.expectEqual(@as(usize, 4), book.sheets().len);
    try testing.expectEqual(Visibility.hidden, book.sheets()[1].visibility);
    try testing.expectEqual(Visibility.very_hidden, book.sheets()[2].visibility);
    const second = try book.rows(1, .{});
    defer second.deinit();
    try testing.expectEqual(@as(f64, 2), (try second.next()).?.cells[0].value.number);
    const third = try book.rows(2, .{});
    defer third.deinit();
    try testing.expect(try third.next() == null);
    // A chart sheet has no rows to read.
    try testing.expectError(error.Unsupported, book.rows(3, .{}));
}

test "what is not an .xlsx: old .xls, encrypted files, .xlsb, a zip without a workbook" {
    const ole = "\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" ++ @as([600]u8, @splat(0));
    try testing.expectError(error.Unsupported, Reader.open(testing.allocator, ole, .{}));
    const encrypted = ole ++ "E\x00n\x00c\x00r\x00y\x00p\x00t\x00e\x00d\x00P\x00a\x00c\x00k\x00a\x00g\x00e\x00";
    try testing.expectError(error.Encrypted, Reader.open(testing.allocator, encrypted, .{}));
    try testing.expectError(error.InvalidZip, Reader.open(testing.allocator, "Nome,Idade\nAna,30\n", .{}));
    try testing.expectError(error.InvalidZip, Reader.open(testing.allocator, "", .{}));

    const xlsb = try package(&.{ .{ "_rels/.rels", root_rels }, .{ "xl/workbook.bin", "\x83\x01\x00" } });
    defer testing.allocator.free(xlsb);
    try testing.expectError(error.Unsupported, Reader.open(testing.allocator, xlsb, .{}));
    const plain_zip = try package(&.{.{ "readme.txt", "hello" }});
    defer testing.allocator.free(plain_zip);
    try testing.expectError(error.InvalidFile, Reader.open(testing.allocator, plain_zip, .{}));
    const no_sheet_part = try package(&.{ .{ "_rels/.rels", root_rels }, .{ "xl/workbook.xml", one_sheet_workbook }, .{ "xl/_rels/workbook.xml.rels", one_sheet_rels } });
    defer testing.allocator.free(no_sheet_part);
    try testing.expectError(error.InvalidFile, Reader.open(testing.allocator, no_sheet_part, .{}));
}

test "hostile sheets: giant references, rows out of order, bad values" {
    const open_tag = "<worksheet " ++ ns ++ "><sheetData>";
    const close_tag = "</sheetData></worksheet>";
    const cases = [_]struct { Error, LimitKind, []const u8 }{
        // A tiny file must not turn into billions of rows or columns.
        .{ error.LimitExceeded, .rows, "<row r=\"4000000000\"><c r=\"A4000000000\"><v>1</v></c></row>" },
        .{ error.LimitExceeded, .rows, "<row r=\"1048577\"/>" },
        .{ error.LimitExceeded, .rows, "<row r=\"99999999999999999999999\"/>" },
        .{ error.LimitExceeded, .columns, "<row r=\"1\"><c r=\"XFE1\"><v>1</v></c></row>" },
        .{ error.LimitExceeded, .columns, "<row r=\"1\"><c r=\"AAAAAAAAAAAA1\"><v>1</v></c></row>" },
        .{ error.LimitExceeded, .rows, "<row r=\"1\"/><row r=\"2\"/><row r=\"3\"/><row r=\"4\"/>" },
    };
    inline for (cases) |case| {
        const bytes = try handmade(.{ .sheet = open_tag ++ case[2] ++ close_tag });
        defer testing.allocator.free(bytes);
        const book = try Reader.open(testing.allocator, bytes, .{ .max_rows = 3 });
        defer book.deinit();
        const rows = try book.rows(0, .{});
        defer rows.deinit();
        const result = while (true) {
            const row = rows.next() catch |err| break err;
            if (row == null) break error.TestUnexpectedResult;
        };
        try testing.expectEqual(@as(anyerror, case[0]), result);
        try testing.expectEqual(@as(?LimitKind, case[1]), book.diagnostic.limit);
        try testing.expectEqual(Part.sheet, book.diagnostic.part);
    }

    const invalid = [_][]const u8{
        "<row r=\"2\"/><row r=\"1\"/>", // rows out of order
        "<row r=\"2\"/><row r=\"2\"/>",
        "<row r=\"0\"/>",
        "<row r=\"abc\"/>",
        "<row r=\"1\"><c r=\"B1\"><v>1</v></c><c r=\"A1\"><v>2</v></c></row>", // cells out of order
        "<row r=\"1\"><c r=\"A2\"><v>1</v></c></row>", // a cell that says it is on another row
        "<row r=\"1\"><c r=\"1A\"><v>1</v></c></row>",
        "<row r=\"1\"><c r=\"A1\" t=\"s\"><v>7</v></c></row>", // no such shared string
        "<row r=\"1\"><c r=\"A1\" t=\"s\"><v>x</v></c></row>",
        "<row r=\"1\"><c r=\"A1\"><v>twelve</v></c></row>",
        "<row r=\"1\"><c r=\"A1\"><v>1e999</v></c></row>",
        "<row r=\"1\"><c r=\"A1\" t=\"b\"><v>maybe</v></c></row>",
    };
    inline for (invalid) |body| try expectHandError(error.InvalidFile, .{ .sheet = open_tag ++ body ++ close_tag }, .{});

    // Text limits, counted as Excel counts.
    try expectHandError(error.LimitExceeded, .{ .sheet = open_tag ++ "<row><c t=\"str\"><v>123456</v></c></row>" ++ close_tag }, .{ .max_cell_text = 5 });
    try expectHandError(error.LimitExceeded, .{ .sheet = open_tag ++ "<row><c t=\"inlineStr\"><is><t>123456</t></is></c></row>" ++ close_tag }, .{ .max_cell_text = 5 });
    try expectHandError(error.LimitExceeded, .{ .sheet = open_tag ++ "<row><c t=\"s\"><v>0</v></c></row>" ++ close_tag, .strings = "<sst " ++ ns ++ "><si><t>123456</t></si></sst>" }, .{ .max_cell_text = 5 });
    try expectHandError(error.LimitExceeded, .{ .sheet = open_tag ++ close_tag ++ "", .strings = "<sst " ++ ns ++ " count=\"4000000000\" uniqueCount=\"4000000000\"><si><t>0123456789</t></si><si><t>0123456789</t></si></sst>" }, .{ .max_shared_strings_bytes = 15 });
    try expectHandError(error.LimitExceeded, .{ .sheet = "<worksheet " ++ ns ++ "><sheetData/><mergeCells><mergeCell ref=\"A1:B1\"/><mergeCell ref=\"A2:B2\"/><mergeCell ref=\"A3:B3\"/></mergeCells></worksheet>" }, .{ .max_merged_ranges = 2 });
    // XML-level problems surface as such, wherever they are.
    try expectHandError(error.InvalidXml, .{ .sheet = "<!DOCTYPE x [<!ENTITY a \"aaaa\">]><worksheet " ++ ns ++ "><sheetData><row><c t=\"str\"><v>&a;</v></c></row></sheetData></worksheet>" }, .{});
    try expectHandError(error.InvalidXml, .{ .sheet = open_tag ++ "<row><c t=\"str\"><v>caf\xe9</v></c></row>" ++ close_tag }, .{});
    try expectHandError(error.InvalidXml, .{ .sheet = open_tag ++ "<row><c>" }, .{});
    try expectHandError(error.LimitExceeded, .{ .sheet = open_tag ++ "<row><c><a><b><c><d><e/></d></c></b></a></c></row>" ++ close_tag }, .{ .xml = .{ .max_depth = 6 } });
    // A count that promises billions of strings allocates nothing by itself.
    try expectDump("", .{ .sheet = open_tag ++ close_tag, .strings = "<sst " ++ ns ++ " count=\"4000000000\" uniqueCount=\"4000000000\"/>" });
}

test "limits on the file itself are reported with their kind" {
    const bytes = try handmade(.{ .sheet = "<worksheet " ++ ns ++ "><sheetData/></worksheet>" });
    defer testing.allocator.free(bytes);
    var diagnostic: Diagnostic = .{};
    try testing.expectError(error.LimitExceeded, Reader.openDiagnosed(testing.allocator, bytes, .{ .max_file_bytes = 100 }, &diagnostic));
    try testing.expectEqual(@as(?LimitKind, .file_bytes), diagnostic.limit);
    try testing.expectError(error.LimitExceeded, Reader.openDiagnosed(testing.allocator, bytes, .{ .max_entries = 2 }, &diagnostic));
    try testing.expectEqual(@as(?LimitKind, .entries), diagnostic.limit);
    try testing.expectError(error.LimitExceeded, Reader.openDiagnosed(testing.allocator, bytes, .{ .max_part_bytes = 10 }, &diagnostic));
    try testing.expectEqual(@as(?LimitKind, .part_bytes), diagnostic.limit);
    try testing.expectError(error.LimitExceeded, Reader.openDiagnosed(testing.allocator, bytes, .{ .max_total_bytes = 100 }, &diagnostic));
    try testing.expectEqual(@as(?LimitKind, .total_bytes), diagnostic.limit);
    // The large profile only raises limits.
    try testing.expect(Limits.large.max_rows >= (Limits{}).max_rows and Limits.large.max_part_bytes > (Limits{}).max_part_bytes);
}

fn sampleBytes(gpa: std.mem.Allocator) ![]u8 {
    const wb = try writer_mod.Workbook.init(gpa);
    defer wb.deinit();
    const sheet = try wb.addSheet("S");
    try sheet.setRow(0, 0, &.{ .{ .text = "Nome" }, .{ .text = "Valor" }, .{ .text = "Data" } }, .{ .bold = true });
    for (1..40) |row| {
        try sheet.set(@intCast(row), 0, .{ .text = if (row % 2 == 0) "Fulano & Cia" else "Beltrano <b>" });
        try sheet.set(@intCast(row), 1, .{ .number = @as(f64, @floatFromInt(row)) * 1.5 });
        try sheet.set(@intCast(row), 2, .{ .date = .{ .year = 2026, .month = 1, .day = @intCast(row % 28 + 1) } });
    }
    try sheet.set(40, 1, .{ .formula = "SUM(B2:B40)" });
    try sheet.mergeCells(.{ .first_row = 42, .first_col = 0, .last_row = 42, .last_col = 2 });
    return wb.toOwnedSlice(gpa);
}

test "running out of memory at any point leaks nothing" {
    const Run = struct {
        fn run(gpa: std.mem.Allocator, bytes: []const u8) !void {
            const got = try dump(gpa, bytes, .{}, .{ .formulas = true });
            gpa.free(got);
        }
    };
    const bytes = try sampleBytes(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{bytes});
}

test "corrupted files never crash or hang, and never read as something else" {
    const bytes = try sampleBytes(testing.allocator);
    defer testing.allocator.free(bytes);
    const baseline = try dump(testing.allocator, bytes, .{}, .{ .formulas = true });
    defer testing.allocator.free(baseline);
    const copy = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(copy);
    var failures: usize = 0;
    var changed: usize = 0;
    // A fixed sequence, so the test is the same on every run.
    var state: u32 = 0x2545F491;
    for (0..4000) |i| {
        state = state *% 1664525 +% 1013904223;
        const at = (state >> 8) % copy.len;
        const saved = copy[at];
        copy[at] = switch (i % 4) {
            0 => saved ^ 0xff,
            1 => '<',
            2 => 0,
            else => @truncate(state >> 24),
        };
        defer copy[at] = saved;
        if (copy[at] == saved) continue;
        changed += 1;
        if (dump(testing.allocator, copy, .{}, .{ .formulas = true })) |got| {
            defer testing.allocator.free(got);
            // The change went unnoticed only because it is in something
            // no reader uses (a timestamp, a part that is not read):
            // every part that is read is covered by its CRC, so what
            // comes out is exactly what the intact file gives.
            try testing.expectEqualStrings(baseline, got);
        } else |err| {
            switch (err) {
                error.InvalidZip, error.InvalidXml, error.InvalidFile, error.LimitExceeded, error.Unsupported, error.Encrypted, error.SheetNotFound => {},
                else => return err,
            }
            failures += 1;
        }
    }
    try testing.expect(failures * 2 > changed);
}

test "number formats: what counts as a date, a time, an elapsed time" {
    const dates = [_][]const u8{ "mm-dd-yy", "d-mmm-yy", "dd/mm/yyyy", "yyyy-mm-dd", "m/d/yy h:mm", "dd/mm/yyyy\\ hh:mm:ss", "[$-416]d \\d\\e mmmm \\d\\e yyyy;@", "mmm-yy", "[$-F800]dddd\\,\\ mmmm\\ dd\\,\\ yyyy", "yyyy\"年\"m\"月\"d\"日\"", "DD/MM/YYYY" };
    for (dates) |code| try testing.expectEqual(NumberKind.date, classifyFormat(code));
    const times = [_][]const u8{ "h:mm", "h:mm:ss", "h:mm AM/PM", "mm:ss", "mmss.0", "hh:mm:ss.000" };
    for (times) |code| try testing.expectEqual(NumberKind.time, classifyFormat(code));
    const durations = [_][]const u8{ "[h]:mm:ss", "[mm]:ss", "[ss]" };
    for (durations) |code| try testing.expectEqual(NumberKind.duration, classifyFormat(code));
    const numbers = [_][]const u8{ "General", "0", "0.00", "#,##0.00", "0%", "00000000000", "@", "#,##0.00\" dias\"", "_-\"R$\"* #,##0.00_-;\\-\"R$\"* #,##0.00_-;_-\"R$\"* \"-\"??_-;_-@_-", "[Red]0.00", "0.00E+00", "#,##0.00_);\\(#,##0.00\\)", "\"h\"0", "[>100]0;0", "" };
    for (numbers) |code| try testing.expectEqual(NumberKind.number, classifyFormat(code));
    try testing.expectEqualStrings("m/d/yy h:mm", builtinFormat(22));
    try testing.expectEqualStrings("General", builtinFormat(0));
    try testing.expectEqualStrings("General", builtinFormat(163));
}

test "the inverse of the writer's _xHHHH_ escape" {
    const cases = [_][2][]const u8{
        .{ "plain", "plain" },
        .{ "a_x000D_b", "a\rb" },
        .{ "_x0001__x0008_", "\x01\x08" },
        .{ "_x005F_x000D_", "_x000D_" },
        .{ "_x00E9_ _x20AC_", "é €" },
        .{ "foo_x12345.txt _x12_ _xZZZZ_ _x", "foo_x12345.txt _x12_ _xZZZZ_ _x" },
        .{ "_xD83D__xDE00_", "_xD83D__xDE00_" },
        .{ "snake_case_x", "snake_case_x" },
    };
    for (cases) |case| {
        const copy = try testing.allocator.dupe(u8, case[0]);
        defer testing.allocator.free(copy);
        try testing.expectEqualStrings(case[1], unescapeCellText(copy));
    }
}

test "moving a shared formula" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("B3*$C$1+C3", try shiftFormula(arena, "B2*$C$1+C2", 1, 0));
    try testing.expectEqualStrings("SUM(C5:$A9,C$2)", try shiftFormula(arena, "SUM(B2:$A6,B$2)", 3, 1));
    try testing.expectEqualStrings("LOG10(B2)+\"A1 stays\"&'A1'!B2+Plan1!B2", try shiftFormula(arena, "LOG10(A1)+\"A1 stays\"&'A1'!A1+Plan1!A1", 1, 1));
    // Off the sheet: the reference is lost, as in a spreadsheet.
    try testing.expectEqualStrings("#REF!+A2", try shiftFormula(arena, "A1+A3", -1, 0));
    try testing.expectEqualStrings("#REF!", try shiftFormula(arena, "XFD1", 0, 1));
    // Names that only look like references are left alone.
    try testing.expectEqualStrings("TAX1RATE*A1B+RATE_A1+C3", try shiftFormula(arena, "TAX1RATE*A1B+RATE_A1+B2", 1, 1));
}
