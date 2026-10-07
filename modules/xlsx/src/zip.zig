//! The package container: a .xlsx is a zip archive of named parts.
//!
//! The workbook code never writes zip bytes itself. It builds each part
//! (a name and its content) and hands it to a `Packager`. `StoreZip` is
//! the packager shipped today: every entry is stored (no compression),
//! with its CRC-32 and sizes written in the local header, so the output
//! needs no data descriptors, no zip64 and no seeking — it can go to
//! any `std.Io.Writer`.
//!
//! The output is deterministic: entries keep the order they were added
//! in and carry a fixed timestamp (1980-01-01 00:00:00, the zip epoch,
//! which is also what Excel writes).
//!
//! Where deflate goes: see `StoreZip.addPart`. Only the bytes written
//! after the local header, the `method` field and the compressed size
//! change; nothing outside this file has to know.

const std = @import("std");
const Writer = std.Io.Writer;

pub const Error = error{
    /// The part name is empty, too long, not plain ASCII, absolute,
    /// contains a backslash, or has an empty, `.` or `..` segment.
    InvalidPartName,
    /// A part with this name (compared without case) was already added.
    DuplicatePartName,
    /// More than 65,535 entries, or sizes/offsets past 4 GiB. zip64 is
    /// not implemented.
    ArchiveTooLarge,
    OutOfMemory,
    WriteFailed,
};

/// What the workbook writes its parts to. Implement this to replace the
/// container (a compressing zip, a directory on disk for debugging, a
/// test double that records the parts).
///
/// `addPart` is called once per part, in a fixed order, and `finish`
/// once at the end. `content` is only valid during the call.
pub const Packager = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        addPart: *const fn (ptr: *anyopaque, name: []const u8, content: []const u8) Error!void,
        finish: *const fn (ptr: *anyopaque) Error!void,
    };

    pub fn addPart(p: Packager, name: []const u8, content: []const u8) Error!void {
        return p.vtable.addPart(p.ptr, name, content);
    }

    pub fn finish(p: Packager) Error!void {
        return p.vtable.finish(p.ptr);
    }
};

/// Longest part name accepted. The zip format allows 65,535 bytes; no
/// part of a workbook comes close to this.
pub const max_part_name_len = 255;

/// Checks a part name the way a careful reader would: forward slashes
/// only, relative, printable ASCII, no empty, `.` or `..` segment.
pub fn validatePartName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > max_part_name_len) return error.InvalidPartName;
    if (name[0] == '/' or name[name.len - 1] == '/') return error.InvalidPartName;
    for (name) |c| {
        if (c < 0x20 or c > 0x7e or c == '\\') return error.InvalidPartName;
    }
    var segments = std.mem.splitScalar(u8, name, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return error.InvalidPartName;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidPartName;
    }
}

const local_header_signature = "PK\x03\x04";
const central_header_signature = "PK\x01\x02";
const end_record_signature = "PK\x05\x06";

/// "Version needed to extract" 2.0: the baseline every reader accepts.
/// LibreOffice has refused archives that claim 4.5 without needing it.
const version_needed: u16 = 20;
const method_store: u16 = 0;
/// 1980-01-01 in MS-DOS format: year 0, month 1, day 1.
const dos_date: u16 = 0x0021;
const dos_time: u16 = 0;

/// A zip writer that stores every entry uncompressed.
pub const StoreZip = struct {
    allocator: std.mem.Allocator,
    out: *Writer,
    entries: std.ArrayList(Entry) = .empty,
    /// Bytes written to `out` so far, i.e. where the next header starts.
    offset: u64 = 0,
    finished: bool = false,

    const Entry = struct {
        name: []const u8,
        crc: u32,
        size: u32,
        offset: u32,
    };

    /// `out` is not flushed by this type: flush it after `finish` if it
    /// is buffered (a file or socket writer).
    pub fn init(allocator: std.mem.Allocator, out: *Writer) StoreZip {
        return .{ .allocator = allocator, .out = out };
    }

    pub fn deinit(self: *StoreZip) void {
        for (self.entries.items) |entry| self.allocator.free(entry.name);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn packager(self: *StoreZip) Packager {
        return .{ .ptr = self, .vtable = &.{ .addPart = addPartOpaque, .finish = finishOpaque } };
    }

    fn addPartOpaque(ptr: *anyopaque, name: []const u8, content: []const u8) Error!void {
        const self: *StoreZip = @ptrCast(@alignCast(ptr));
        return self.addPart(name, content);
    }

    fn finishOpaque(ptr: *anyopaque) Error!void {
        const self: *StoreZip = @ptrCast(@alignCast(ptr));
        return self.finish();
    }

    /// Writes one entry: local header, then the content.
    pub fn addPart(self: *StoreZip, name: []const u8, content: []const u8) Error!void {
        std.debug.assert(!self.finished);
        try validatePartName(name);
        for (self.entries.items) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return error.DuplicatePartName;
        }
        if (self.entries.items.len >= std.math.maxInt(u16)) return error.ArchiveTooLarge;

        const size = std.math.cast(u32, content.len) orelse return error.ArchiveTooLarge;
        const offset = std.math.cast(u32, self.offset) orelse return error.ArchiveTooLarge;
        const crc = std.hash.Crc32.hash(content);

        const owned_name = try self.allocator.dupe(u8, name);
        self.entries.append(self.allocator, .{ .name = owned_name, .crc = crc, .size = size, .offset = offset }) catch |err| {
            self.allocator.free(owned_name);
            return err;
        };

        // Compression seam. To deflate instead of store: compress
        // `content` into a buffer with std.compress.flate (container
        // `.raw`), write method 8 and that buffer's length as the
        // compressed size here and in the central directory, and write
        // the buffer instead of `content`. The CRC and the uncompressed
        // size stay those of `content`. Keep "version needed" at 20.
        const w = self.out;
        try w.writeAll(local_header_signature);
        try w.writeInt(u16, version_needed, .little);
        try w.writeInt(u16, 0, .little); // flags: sizes are in this header
        try w.writeInt(u16, method_store, .little);
        try w.writeInt(u16, dos_time, .little);
        try w.writeInt(u16, dos_date, .little);
        try w.writeInt(u32, crc, .little);
        try w.writeInt(u32, size, .little); // compressed size
        try w.writeInt(u32, size, .little); // uncompressed size
        try w.writeInt(u16, @intCast(name.len), .little);
        try w.writeInt(u16, 0, .little); // extra field length
        try w.writeAll(name);
        try w.writeAll(content);

        self.offset += 30 + name.len + content.len;
    }

    /// Writes the central directory and the end record. No part can be
    /// added afterwards.
    pub fn finish(self: *StoreZip) Error!void {
        std.debug.assert(!self.finished);
        self.finished = true;

        const w = self.out;
        const directory_offset = std.math.cast(u32, self.offset) orelse return error.ArchiveTooLarge;
        var directory_size: u64 = 0;
        for (self.entries.items) |entry| {
            try w.writeAll(central_header_signature);
            try w.writeInt(u16, version_needed, .little); // version made by
            try w.writeInt(u16, version_needed, .little);
            try w.writeInt(u16, 0, .little); // flags
            try w.writeInt(u16, method_store, .little);
            try w.writeInt(u16, dos_time, .little);
            try w.writeInt(u16, dos_date, .little);
            try w.writeInt(u32, entry.crc, .little);
            try w.writeInt(u32, entry.size, .little);
            try w.writeInt(u32, entry.size, .little);
            try w.writeInt(u16, @intCast(entry.name.len), .little);
            try w.writeInt(u16, 0, .little); // extra field length
            try w.writeInt(u16, 0, .little); // comment length
            try w.writeInt(u16, 0, .little); // disk number
            try w.writeInt(u16, 0, .little); // internal attributes
            try w.writeInt(u32, 0, .little); // external attributes
            try w.writeInt(u32, entry.offset, .little);
            try w.writeAll(entry.name);
            directory_size += 46 + entry.name.len;
        }
        const directory_size32 = std.math.cast(u32, directory_size) orelse return error.ArchiveTooLarge;
        if (@as(u64, directory_offset) + directory_size > std.math.maxInt(u32)) return error.ArchiveTooLarge;

        const count: u16 = @intCast(self.entries.items.len);
        try w.writeAll(end_record_signature);
        try w.writeInt(u16, 0, .little); // this disk
        try w.writeInt(u16, 0, .little); // disk with the directory
        try w.writeInt(u16, count, .little);
        try w.writeInt(u16, count, .little);
        try w.writeInt(u32, directory_size32, .little);
        try w.writeInt(u32, directory_offset, .little);
        try w.writeInt(u16, 0, .little); // comment length
    }
};

const testing = std.testing;

fn buildArchive(parts: []const [2][]const u8) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    var archive: StoreZip = .init(testing.allocator, &out.writer);
    defer archive.deinit();
    const p = archive.packager();
    for (parts) |part| try p.addPart(part[0], part[1]);
    try p.finish();
    return out.toOwnedSlice();
}

test "an archive with no parts is just the end record" {
    const bytes = try buildArchive(&.{});
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "PK\x05\x06" ++ @as([18]u8, @splat(0)), bytes);
}

test "one stored entry, byte for byte" {
    const bytes = try buildArchive(&.{.{ "a.txt", "hello" }});
    defer testing.allocator.free(bytes);

    // CRC-32 of "hello" is 0x3610a686.
    const local = "PK\x03\x04" ++ "\x14\x00" ++ "\x00\x00" ++ "\x00\x00" ++ "\x00\x00" ++ "\x21\x00" ++
        "\x86\xa6\x10\x36" ++ "\x05\x00\x00\x00" ++ "\x05\x00\x00\x00" ++ "\x05\x00" ++ "\x00\x00" ++
        "a.txt" ++ "hello";
    const central = "PK\x01\x02" ++ "\x14\x00" ++ "\x14\x00" ++ "\x00\x00" ++ "\x00\x00" ++ "\x00\x00" ++ "\x21\x00" ++
        "\x86\xa6\x10\x36" ++ "\x05\x00\x00\x00" ++ "\x05\x00\x00\x00" ++ "\x05\x00" ++ "\x00\x00" ++ "\x00\x00" ++
        "\x00\x00" ++ "\x00\x00" ++ "\x00\x00\x00\x00" ++ "\x00\x00\x00\x00" ++ "a.txt";
    const end = "PK\x05\x06" ++ "\x00\x00" ++ "\x00\x00" ++ "\x01\x00" ++ "\x01\x00" ++
        "\x33\x00\x00\x00" ++ "\x28\x00\x00\x00" ++ "\x00\x00";
    try testing.expectEqualSlices(u8, local ++ central ++ end, bytes);
}

test "the same parts always give the same bytes" {
    const parts: []const [2][]const u8 = &.{ .{ "[Content_Types].xml", "<Types/>" }, .{ "xl/workbook.xml", "<workbook/>" } };
    const first = try buildArchive(parts);
    defer testing.allocator.free(first);
    const second = try buildArchive(parts);
    defer testing.allocator.free(second);
    try testing.expectEqualSlices(u8, first, second);
}

test "std.zip reads the archive back, and every CRC matches the content" {
    const io = testing.io;
    const parts: []const [2][]const u8 = &.{
        .{ "[Content_Types].xml", "<Types/>" },
        .{ "_rels/.rels", "<Relationships/>" },
        .{ "xl/worksheets/sheet1.xml", "<worksheet>" ++ @as([4000]u8, @splat('x')) ++ "</worksheet>" },
        .{ "empty.bin", "" },
    };
    const bytes = try buildArchive(parts);
    defer testing.allocator.free(bytes);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "t.zip", .data = bytes });
    var file = try tmp.dir.openFile(io, "t.zip", .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);

    var it = try std.zip.Iterator.init(&file_reader);
    var index: usize = 0;
    while (try it.next()) |entry| : (index += 1) {
        var name_buffer: [max_part_name_len]u8 = undefined;
        const name = try entry.getFilename(&file_reader, &name_buffer, .{});
        try testing.expectEqualStrings(parts[index][0], name);
        try testing.expectEqual(std.zip.CompressionMethod.store, entry.compression_method);

        var content: Writer.Allocating = .init(testing.allocator);
        defer content.deinit();
        try entry.extractTo(&file_reader, &content.writer);
        try testing.expectEqualStrings(parts[index][1], content.written());
        // std.zip does not verify checksums itself, so compare here.
        try testing.expectEqual(entry.crc32, std.hash.Crc32.hash(content.written()));
    }
    try testing.expectEqual(parts.len, index);
}

test "hostile part names are refused" {
    const bad = [_][]const u8{
        "",
        "/abs.xml",
        "../evil.xml",
        "xl/../../evil.xml",
        "xl/./workbook.xml",
        "xl//workbook.xml",
        "xl/",
        "xl\\workbook.xml",
        "C:\\workbook.xml",
        "xl/work\x00book.xml",
        "xl/work\nbook.xml",
        "xl/planilha\xc3\xa7.xml",
        &@as([max_part_name_len + 1]u8, @splat('a')),
    };
    for (bad) |name| {
        try testing.expectError(error.InvalidPartName, validatePartName(name));
        try testing.expectError(error.InvalidPartName, buildArchive(&.{.{ name, "x" }}));
    }
    try validatePartName("[Content_Types].xml");
    try validatePartName("xl/worksheets/sheet12.xml");
    try validatePartName("_rels/.rels");
}

test "a part name cannot be used twice, whatever its case" {
    try testing.expectError(error.DuplicatePartName, buildArchive(&.{ .{ "xl/a.xml", "1" }, .{ "xl/a.xml", "2" } }));
    try testing.expectError(error.DuplicatePartName, buildArchive(&.{ .{ "xl/a.xml", "1" }, .{ "XL/A.XML", "2" } }));
}

test "a failing writer surfaces as WriteFailed" {
    var small: [16]u8 = undefined;
    var out: Writer = .fixed(&small);
    var archive: StoreZip = .init(testing.allocator, &out);
    defer archive.deinit();
    try testing.expectError(error.WriteFailed, archive.addPart("a.txt", "does not fit in sixteen bytes"));
}
