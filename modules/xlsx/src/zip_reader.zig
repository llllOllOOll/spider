//! Reads a zip archive that is already in memory: the bytes of an
//! uploaded file. It exists because `std.zip` only reads from a file on
//! disk, does not check CRC-32s and trusts the sizes it is told.
//!
//! The archive is read through its central directory, and every entry
//! is checked against its local header before anything is inflated.
//! Content comes out through a `Stream`, in pieces, so a large part
//! never has to exist whole in memory; its size and CRC-32 are checked
//! as the last piece is read.
//!
//! Refused, by design: encrypted entries, zip64, compression methods
//! other than store and deflate, repeated names, names that are
//! absolute or contain `..`, a backslash or a control character,
//! entries that share bytes, and any disagreement between the central
//! directory, the local headers and the data.

const std = @import("std");
const flate = std.compress.flate;

pub const Error = error{
    /// Not a zip archive, truncated, or inconsistent with itself.
    InvalidZip,
    /// A valid archive using something this reader does not handle:
    /// zip64 or a compression method other than store and deflate.
    Unsupported,
    /// The archive, or one of its entries, is encrypted.
    Encrypted,
    /// One of `Limits` was exceeded.
    LimitExceeded,
    OutOfMemory,
};

/// What an archive may claim before it is refused. The sizes are those
/// the archive declares; reading then enforces them.
pub const Limits = struct {
    max_entries: u32 = 1_000,
    /// Largest uncompressed size of one entry.
    max_part_bytes: u64 = 64 << 20,
    /// Largest sum of the uncompressed sizes of all entries.
    max_total_bytes: u64 = 128 << 20,
    /// Largest uncompressed/compressed ratio of one entry.
    max_compression_ratio: u32 = 200,
    /// Entries no larger than this are not held to the ratio: a few
    /// kilobytes of repetitive XML compress very well and are harmless.
    ratio_grace_bytes: u64 = 1 << 20,
};

pub const Method = enum { store, deflate };

pub const Entry = struct {
    /// A slice of the archive's bytes.
    name: []const u8,
    method: Method,
    crc: u32,
    /// The entry's data as stored in the archive.
    compressed: []const u8,
    /// Uncompressed size, as declared.
    size: u64,
};

const end_record_len = 22;
const central_header_len = 46;
const local_header_len = 30;
const flag_encrypted: u16 = 0x0001;
const flag_data_descriptor: u16 = 0x0008;
const flag_strong_encryption: u16 = 0x0040;

fn readInt(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

pub const Archive = struct {
    gpa: std.mem.Allocator,
    entries: []Entry,

    /// Reads the central directory of `bytes` and checks every entry.
    /// `bytes` must outlive the archive and its streams.
    pub fn open(gpa: std.mem.Allocator, bytes: []const u8, limits: Limits) Error!Archive {
        if (bytes.len < end_record_len) return error.InvalidZip;

        // The end record is the last thing in the file, followed only
        // by its own comment.
        const end_at = find_end: {
            var at = bytes.len - end_record_len;
            const lowest = at -| std.math.maxInt(u16);
            while (true) : (at -= 1) {
                if (std.mem.eql(u8, bytes[at..][0..4], "PK\x05\x06") and
                    @as(usize, readInt(u16, bytes, at + 20)) == bytes.len - at - end_record_len) break :find_end at;
                if (at == lowest) return error.InvalidZip;
            }
        };
        if (end_at >= 20 and std.mem.eql(u8, bytes[end_at - 20 ..][0..4], "PK\x06\x07")) return error.Unsupported;
        const count = readInt(u16, bytes, end_at + 10);
        const directory_size = readInt(u32, bytes, end_at + 12);
        const directory_offset = readInt(u32, bytes, end_at + 16);
        if (count == std.math.maxInt(u16) or directory_size == std.math.maxInt(u32) or directory_offset == std.math.maxInt(u32)) return error.Unsupported;
        if (readInt(u16, bytes, end_at + 4) != 0 or readInt(u16, bytes, end_at + 6) != 0) return error.InvalidZip;
        if (readInt(u16, bytes, end_at + 8) != count) return error.InvalidZip;
        if (@as(u64, directory_offset) + directory_size != end_at) return error.InvalidZip;
        if (count > limits.max_entries) return error.LimitExceeded;

        const entries = try gpa.alloc(Entry, count);
        errdefer gpa.free(entries);
        // Where each entry's header and data sit, to detect overlaps.
        const extents = try gpa.alloc([2]u32, count);
        defer gpa.free(extents);

        var at: usize = directory_offset;
        var total: u64 = 0;
        for (entries, extents) |*entry, *extent| {
            if (end_at - at < central_header_len) return error.InvalidZip;
            if (!std.mem.eql(u8, bytes[at..][0..4], "PK\x01\x02")) return error.InvalidZip;
            const flags = readInt(u16, bytes, at + 8);
            const method_id = readInt(u16, bytes, at + 10);
            const crc = readInt(u32, bytes, at + 16);
            const compressed_size = readInt(u32, bytes, at + 20);
            const size = readInt(u32, bytes, at + 24);
            const name_len = readInt(u16, bytes, at + 28);
            const extra_len = readInt(u16, bytes, at + 30);
            const comment_len = readInt(u16, bytes, at + 32);
            const disk = readInt(u16, bytes, at + 34);
            const offset = readInt(u32, bytes, at + 42);
            const next = at + central_header_len + name_len + extra_len + comment_len;
            if (next > end_at) return error.InvalidZip;
            const name = bytes[at + central_header_len ..][0..name_len];
            at = next;

            if (flags & (flag_encrypted | flag_strong_encryption) != 0) return error.Encrypted;
            if (compressed_size == std.math.maxInt(u32) or size == std.math.maxInt(u32) or offset == std.math.maxInt(u32)) return error.Unsupported;
            const method: Method = switch (method_id) {
                0 => .store,
                8 => .deflate,
                else => return error.Unsupported,
            };
            if (disk != 0) return error.InvalidZip;
            try checkName(name);

            // The local header must tell the same story.
            if (@as(u64, offset) + local_header_len > directory_offset) return error.InvalidZip;
            if (!std.mem.eql(u8, bytes[offset..][0..4], "PK\x03\x04")) return error.InvalidZip;
            const local_flags = readInt(u16, bytes, offset + 6);
            if (local_flags & (flag_encrypted | flag_strong_encryption) != 0) return error.Encrypted;
            if (readInt(u16, bytes, offset + 8) != method_id) return error.InvalidZip;
            const local_name_len = readInt(u16, bytes, offset + 26);
            const local_extra_len = readInt(u16, bytes, offset + 28);
            const data_start = @as(u64, offset) + local_header_len + local_name_len + local_extra_len;
            const data_end = data_start + compressed_size;
            if (data_end > directory_offset) return error.InvalidZip;
            if (!std.mem.eql(u8, bytes[offset + local_header_len ..][0..local_name_len], name)) return error.InvalidZip;
            if (local_flags & flag_data_descriptor == 0) {
                // Without a data descriptor the local header carries the
                // sizes and the CRC too.
                if (readInt(u32, bytes, offset + 14) != crc or
                    readInt(u32, bytes, offset + 18) != compressed_size or
                    readInt(u32, bytes, offset + 22) != size) return error.InvalidZip;
            }
            if (method == .store and compressed_size != size) return error.InvalidZip;

            if (size > limits.max_part_bytes) return error.LimitExceeded;
            total += size;
            if (total > limits.max_total_bytes) return error.LimitExceeded;
            if (size > limits.ratio_grace_bytes and size > @as(u64, compressed_size) * limits.max_compression_ratio) return error.LimitExceeded;

            entry.* = .{
                .name = name,
                .method = method,
                .crc = crc,
                .compressed = bytes[@intCast(data_start)..@intCast(data_end)],
                .size = size,
            };
            extent.* = .{ offset, @intCast(data_end) };
        }
        if (at != end_at) return error.InvalidZip;

        for (entries, 0..) |entry, i| {
            for (entries[0..i]) |earlier| {
                if (std.ascii.eqlIgnoreCase(earlier.name, entry.name)) return error.InvalidZip;
            }
        }
        // Entries may not share bytes: that is how a small archive
        // pretends to hold the same large content many times.
        std.mem.sort([2]u32, extents, {}, struct {
            fn before(_: void, a: [2]u32, b: [2]u32) bool {
                return a[0] < b[0];
            }
        }.before);
        for (extents[0..extents.len -| 1], extents[@min(1, extents.len)..]) |a, b| {
            if (b[0] < a[1]) return error.InvalidZip;
        }

        return .{ .gpa = gpa, .entries = entries };
    }

    pub fn deinit(self: *Archive) void {
        self.gpa.free(self.entries);
        self.* = undefined;
    }

    /// Finds an entry by name, ignoring ASCII case (part names in an
    /// Office package do not depend on case).
    pub fn find(self: *const Archive, name: []const u8) ?*const Entry {
        for (self.entries) |*entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry;
        }
        return null;
    }

    /// Starts reading an entry's content. Free the stream with
    /// `Stream.deinit`.
    pub fn openStream(self: *const Archive, gpa: std.mem.Allocator, entry: *const Entry) Error!*Stream {
        _ = self;
        return Stream.create(gpa, entry.*);
    }

    /// Reads a whole entry into memory, for the small parts. Refuses
    /// entries larger than `max_bytes`. The caller frees the result.
    pub fn readAll(self: *const Archive, gpa: std.mem.Allocator, entry: *const Entry, max_bytes: u64) Error![]u8 {
        if (entry.size > max_bytes) return error.LimitExceeded;
        const stream = try self.openStream(gpa, entry);
        defer stream.deinit();
        const content = try gpa.alloc(u8, @intCast(entry.size));
        errdefer gpa.free(content);
        var filled: usize = 0;
        while (filled < content.len) {
            const n = try stream.read(content[filled..]);
            if (n == 0) return error.InvalidZip;
            filled += n;
        }
        // One more read: it must report the end, which is also where
        // the size and the CRC are checked.
        var one: [1]u8 = undefined;
        if (try stream.read(&one) != 0) return error.InvalidZip;
        return content;
    }
};

/// The content of one entry, read in pieces.
pub const Stream = struct {
    gpa: std.mem.Allocator,
    entry: Entry,
    /// What is left of a stored entry.
    stored: []const u8,
    input: std.Io.Reader,
    decompress: flate.Decompress,
    window: []u8,
    crc: std.hash.Crc32,
    produced: u64,
    finished: bool,

    fn create(gpa: std.mem.Allocator, entry: Entry) Error!*Stream {
        const self = try gpa.create(Stream);
        errdefer gpa.destroy(self);
        // The decompressor is always given a window buffer: without one
        // it can stall on some inputs in the Zig this module supports.
        const window: []u8 = if (entry.method == .deflate) try gpa.alloc(u8, flate.max_window_len) else &.{};
        self.* = .{
            .gpa = gpa,
            .entry = entry,
            .stored = entry.compressed,
            .input = .fixed(entry.compressed),
            .decompress = undefined,
            .window = window,
            .crc = .init(),
            .produced = 0,
            .finished = false,
        };
        if (entry.method == .deflate) self.decompress = .init(&self.input, .raw, window);
        return self;
    }

    pub fn deinit(self: *Stream) void {
        const gpa = self.gpa;
        gpa.free(self.window);
        gpa.destroy(self);
    }

    /// Fills `dest` with the next bytes of content and returns how many
    /// were written; 0 means the end (`dest` must not be empty). The
    /// entry's size and CRC-32 are checked when the end is reached:
    /// content that disagrees with them is `error.InvalidZip`, so do
    /// not act on what was read until the end has been confirmed.
    pub fn read(self: *Stream, dest: []u8) Error!usize {
        std.debug.assert(dest.len > 0);
        if (self.finished) return 0;
        const n: usize = switch (self.entry.method) {
            .store => n: {
                const n = @min(dest.len, self.stored.len);
                @memcpy(dest[0..n], self.stored[0..n]);
                self.stored = self.stored[n..];
                break :n n;
            },
            .deflate => self.decompress.reader.readSliceShort(dest) catch return error.InvalidZip,
        };
        if (n == 0) {
            if (self.produced != self.entry.size or self.crc.final() != self.entry.crc) return error.InvalidZip;
            self.finished = true;
            return 0;
        }
        self.produced += n;
        if (self.produced > self.entry.size) return error.InvalidZip;
        self.crc.update(dest[0..n]);
        return n;
    }
};

/// A relative path with `/` separators, valid UTF-8, no control
/// characters, no empty, `.` or `..` segment. A trailing `/` (a
/// directory entry) is accepted.
fn checkName(name: []const u8) Error!void {
    if (name.len == 0 or name[0] == '/') return error.InvalidZip;
    if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidZip;
    for (name) |c| {
        if (c < 0x20 or c == 0x7f or c == '\\') return error.InvalidZip;
    }
    const path = if (name[name.len - 1] == '/') name[0 .. name.len - 1] else name;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidZip;
    }
}

const testing = std.testing;
const Writer = std.Io.Writer;

/// One entry of a hand-built archive, with knobs to make it wrong.
const TestEntry = struct {
    name: []const u8,
    data: []const u8 = "",
    deflate: bool = false,
    /// Sizes and CRC after the data instead of in the local header.
    descriptor: bool = false,
    flags: u16 = 0,
    method: ?u16 = null,
    crc_xor: u32 = 0,
    declared_size: ?u32 = null,
    local_name: ?[]const u8 = null,
    /// Points the central directory at another entry's data.
    same_data_as: ?usize = null,
};

const TestArchive = struct {
    entries: []const TestEntry,
    declared_count: ?u16 = null,
    zip64_locator: bool = false,
    directory_offset_delta: i32 = 0,
    comment: []const u8 = "",
};

fn buildTestZip(archive: TestArchive) ![]u8 {
    const gpa = testing.allocator;
    var out: Writer.Allocating = try .initCapacity(gpa, 4096);
    errdefer out.deinit();
    const w = &out.writer;
    var directory: Writer.Allocating = .init(gpa);
    defer directory.deinit();
    var offsets: [16]u32 = undefined;

    for (archive.entries, 0..) |entry, index| {
        var payload: Writer.Allocating = try .initCapacity(gpa, 4096);
        defer payload.deinit();
        if (entry.deflate) {
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var compress: std.compress.flate.Compress = try .init(&payload.writer, &window, .raw, .default);
            try compress.writer.writeAll(entry.data);
            try compress.finish();
        } else try payload.writer.writeAll(entry.data);

        const crc = std.hash.Crc32.hash(entry.data) ^ entry.crc_xor;
        const compressed_size: u32 = @intCast(payload.written().len);
        const size: u32 = entry.declared_size orelse @intCast(entry.data.len);
        const flags: u16 = entry.flags | (if (entry.descriptor) @as(u16, 0x0008) else 0);
        const method: u16 = entry.method orelse (if (entry.deflate) @as(u16, 8) else 0);
        const local_name = entry.local_name orelse entry.name;

        var offset: u32 = @intCast(out.written().len);
        if (entry.same_data_as) |other| {
            offset = offsets[other];
        } else {
            try w.writeAll("PK\x03\x04");
            try w.writeInt(u16, 20, .little);
            try w.writeInt(u16, flags, .little);
            try w.writeInt(u16, method, .little);
            try w.writeInt(u16, 0, .little);
            try w.writeInt(u16, 0x21, .little);
            try w.writeInt(u32, if (entry.descriptor) 0 else crc, .little);
            try w.writeInt(u32, if (entry.descriptor) 0 else compressed_size, .little);
            try w.writeInt(u32, if (entry.descriptor) 0 else size, .little);
            try w.writeInt(u16, @intCast(local_name.len), .little);
            try w.writeInt(u16, 0, .little);
            try w.writeAll(local_name);
            try w.writeAll(payload.written());
            if (entry.descriptor) {
                try w.writeAll("PK\x07\x08");
                try w.writeInt(u32, crc, .little);
                try w.writeInt(u32, compressed_size, .little);
                try w.writeInt(u32, size, .little);
            }
        }
        offsets[index] = offset;

        const d = &directory.writer;
        try d.writeAll("PK\x01\x02");
        try d.writeInt(u16, 20, .little);
        try d.writeInt(u16, 20, .little);
        try d.writeInt(u16, flags, .little);
        try d.writeInt(u16, method, .little);
        try d.writeInt(u16, 0, .little);
        try d.writeInt(u16, 0x21, .little);
        try d.writeInt(u32, crc, .little);
        try d.writeInt(u32, compressed_size, .little);
        try d.writeInt(u32, size, .little);
        try d.writeInt(u16, @intCast(entry.name.len), .little);
        try d.writeInt(u16, 0, .little);
        try d.writeInt(u16, 0, .little);
        try d.writeInt(u16, 0, .little);
        try d.writeInt(u16, 0, .little);
        try d.writeInt(u32, 0, .little);
        try d.writeInt(u32, offset, .little);
        try d.writeAll(entry.name);
    }

    const directory_offset: u32 = @intCast(out.written().len);
    try w.writeAll(directory.written());
    if (archive.zip64_locator) {
        try w.writeAll("PK\x06\x07");
        try w.writeAll(&@as([16]u8, @splat(0)));
    }
    const count: u16 = archive.declared_count orelse @intCast(archive.entries.len);
    try w.writeAll("PK\x05\x06");
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, count, .little);
    try w.writeInt(u16, count, .little);
    try w.writeInt(u32, @intCast(directory.written().len), .little);
    try w.writeInt(u32, @intCast(@as(i64, directory_offset) + archive.directory_offset_delta), .little);
    try w.writeInt(u16, @intCast(archive.comment.len), .little);
    try w.writeAll(archive.comment);
    return out.toOwnedSlice();
}

fn expectOpenError(expected: Error, archive: TestArchive, limits: Limits) !void {
    const bytes = try buildTestZip(archive);
    defer testing.allocator.free(bytes);
    try testing.expectError(expected, Archive.open(testing.allocator, bytes, limits));
}

/// Opens the archive and reads its first entry whole.
fn readFirst(archive: TestArchive) Error![]u8 {
    const bytes = buildTestZip(archive) catch return error.OutOfMemory;
    defer testing.allocator.free(bytes);
    var opened = try Archive.open(testing.allocator, bytes, .{});
    defer opened.deinit();
    return opened.readAll(testing.allocator, &opened.entries[0], 1 << 20);
}

test "reads stored and deflated entries, with and without a data descriptor" {
    var big: [50_000]u8 = undefined;
    for (&big, 0..) |*c, i| c.* = "<c r=\"A1\"><v>1</v></c>"[i % 22];
    const bytes = try buildTestZip(.{ .entries = &.{
        .{ .name = "[Content_Types].xml", .data = "<Types/>" },
        .{ .name = "xl/worksheets/sheet1.xml", .data = &big, .deflate = true },
        .{ .name = "xl/styles.xml", .data = &big, .deflate = true, .descriptor = true },
        .{ .name = "xl/empty.xml", .data = "" },
        .{ .name = "xl/media/", .data = "" },
    }, .comment = "made by a test" });
    defer testing.allocator.free(bytes);

    var archive = try Archive.open(testing.allocator, bytes, .{});
    defer archive.deinit();
    try testing.expectEqual(@as(usize, 5), archive.entries.len);
    try testing.expectEqualStrings("xl/worksheets/sheet1.xml", archive.entries[1].name);
    try testing.expectEqual(@as(u64, big.len), archive.entries[1].size);

    // Lookup ignores ASCII case, as part names do.
    try testing.expect(archive.find("XL/Worksheets/Sheet1.xml") == &archive.entries[1]);
    try testing.expect(archive.find("xl/missing.xml") == null);

    for ([_]usize{ 0, 1, 2, 3 }) |index| {
        const content = try archive.readAll(testing.allocator, &archive.entries[index], 1 << 20);
        defer testing.allocator.free(content);
        const expected: []const u8 = switch (index) {
            0 => "<Types/>",
            1, 2 => &big,
            else => "",
        };
        try testing.expectEqualStrings(expected, content);
    }

    // Streaming: a large part comes out in pieces of whatever size is asked.
    var stream = try archive.openStream(testing.allocator, &archive.entries[1]);
    defer stream.deinit();
    var total: usize = 0;
    var piece: [777]u8 = undefined;
    while (true) {
        const n = try stream.read(&piece);
        if (n == 0) break;
        try testing.expectEqualStrings(big[total..][0..n], piece[0..n]);
        total += n;
    }
    try testing.expectEqual(big.len, total);
    try testing.expectEqual(@as(usize, 0), try stream.read(&piece));
}

test "reads what this module's own writer produces" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var store: @import("zip.zig").StoreZip = .init(testing.allocator, &out.writer);
    defer store.deinit();
    try store.addPart("[Content_Types].xml", "<Types/>");
    try store.addPart("xl/workbook.xml", "<workbook/>");
    try store.finish();

    var archive = try Archive.open(testing.allocator, out.written(), .{});
    defer archive.deinit();
    const content = try archive.readAll(testing.allocator, archive.find("xl/workbook.xml").?, 1 << 20);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("<workbook/>", content);
}

test "a wrong CRC or a wrong declared size is caught when the entry is read" {
    try testing.expectError(error.InvalidZip, readFirst(.{ .entries = &.{.{ .name = "a.xml", .data = "hello world", .crc_xor = 1 }} }));
    try testing.expectError(error.InvalidZip, readFirst(.{ .entries = &.{.{ .name = "a.xml", .data = "hello world", .deflate = true, .crc_xor = 0x8000_0000 }} }));
    // Declared larger than what the data inflates to, and smaller.
    try testing.expectError(error.InvalidZip, readFirst(.{ .entries = &.{.{ .name = "a.xml", .data = "hello world", .deflate = true, .declared_size = 500 }} }));
    try testing.expectError(error.InvalidZip, readFirst(.{ .entries = &.{.{ .name = "a.xml", .data = "hello world", .deflate = true, .declared_size = 5 }} }));
    // A stored entry whose two sizes disagree is refused on opening.
    try expectOpenError(error.InvalidZip, .{ .entries = &.{.{ .name = "a.xml", .data = "hello world", .declared_size = 5 }} }, .{});
}

test "what is refused on opening" {
    const ok: TestEntry = .{ .name = "a.xml", .data = "x" };
    // Encrypted, in either flag.
    try expectOpenError(error.Encrypted, .{ .entries = &.{.{ .name = "a.xml", .data = "x", .flags = 0x0001 }} }, .{});
    try expectOpenError(error.Encrypted, .{ .entries = &.{.{ .name = "a.xml", .data = "x", .flags = 0x0040 }} }, .{});
    // zip64 and compression methods other than store and deflate.
    try expectOpenError(error.Unsupported, .{ .entries = &.{ok}, .zip64_locator = true }, .{});
    try expectOpenError(error.Unsupported, .{ .entries = &.{.{ .name = "a.xml", .data = "x", .method = 12 }} }, .{});
    try expectOpenError(error.Unsupported, .{ .entries = &.{.{ .name = "a.xml", .data = "x", .method = 99 }} }, .{});
    // The same name twice, whatever the case.
    try expectOpenError(error.InvalidZip, .{ .entries = &.{ ok, ok } }, .{});
    try expectOpenError(error.InvalidZip, .{ .entries = &.{ ok, .{ .name = "A.XML", .data = "y" } } }, .{});
    // Names that try to leave the archive, or hide something.
    for ([_][]const u8{ "../a.xml", "xl/../../a.xml", "/abs.xml", "xl\\a.xml", "C:\\a.xml", "xl/a\x00.xml", "xl/a\n.xml", "xl/./a.xml", "xl//a.xml", "", "\xff\xfe.xml" }) |name| {
        try expectOpenError(error.InvalidZip, .{ .entries = &.{.{ .name = name, .data = "x" }} }, .{});
    }
    // A central directory that does not agree with the rest.
    try expectOpenError(error.InvalidZip, .{ .entries = &.{ok}, .declared_count = 2 }, .{});
    try expectOpenError(error.InvalidZip, .{ .entries = &.{ ok, .{ .name = "b.xml", .data = "y" } }, .declared_count = 1 }, .{});
    try expectOpenError(error.InvalidZip, .{ .entries = &.{ok}, .directory_offset_delta = 3 }, .{});
    try expectOpenError(error.InvalidZip, .{ .entries = &.{ok}, .directory_offset_delta = -3 }, .{});
    try expectOpenError(error.InvalidZip, .{ .entries = &.{.{ .name = "a.xml", .data = "x", .local_name = "b.xml" }} }, .{});
    // Two entries over the same bytes: how a small file claims to hold a huge one many times.
    try expectOpenError(error.InvalidZip, .{ .entries = &.{ ok, .{ .name = "b.xml", .data = "x", .same_data_as = 0 } } }, .{});
    // Not a zip at all.
    try testing.expectError(error.InvalidZip, Archive.open(testing.allocator, "", .{}));
    try testing.expectError(error.InvalidZip, Archive.open(testing.allocator, "just some text, long enough to hold an end record", .{}));
}

test "limits: entries, size of a part, total size and compression ratio" {
    const zeros: [200_000]u8 = @splat(0);
    const bomb: TestArchive = .{ .entries = &.{.{ .name = "xl/worksheets/sheet1.xml", .data = &zeros, .deflate = true }} };
    try expectOpenError(error.LimitExceeded, bomb, .{ .max_compression_ratio = 100, .ratio_grace_bytes = 1000 });
    try expectOpenError(error.LimitExceeded, bomb, .{ .max_part_bytes = 199_999, .max_compression_ratio = 100_000 });
    try expectOpenError(error.LimitExceeded, .{ .entries = &.{ bomb.entries[0], .{ .name = "b.xml", .data = &zeros, .deflate = true } } }, .{ .max_total_bytes = 399_999, .max_compression_ratio = 100_000 });
    try expectOpenError(error.LimitExceeded, .{ .entries = &.{ .{ .name = "a", .data = "1" }, .{ .name = "b", .data = "2" }, .{ .name = "c", .data = "3" } } }, .{ .max_entries = 2 });

    // The same archives pass with room to spare, and small parts are not held to the ratio.
    const bytes = try buildTestZip(bomb);
    defer testing.allocator.free(bytes);
    var archive = try Archive.open(testing.allocator, bytes, .{ .max_compression_ratio = 100_000 });
    defer archive.deinit();
    var small = try Archive.open(testing.allocator, bytes, .{ .max_compression_ratio = 100, .ratio_grace_bytes = 200_000 });
    defer small.deinit();
    // Reading whole into memory has its own cap.
    try testing.expectError(error.LimitExceeded, archive.readAll(testing.allocator, &archive.entries[0], 1000));
}

test "a truncated or corrupted archive is refused, never read out of bounds" {
    var big: [20_000]u8 = undefined;
    for (&big, 0..) |*c, i| c.* = @intCast(i * 7 % 251);
    const bytes = try buildTestZip(.{ .entries = &.{
        .{ .name = "[Content_Types].xml", .data = "<Types/>" },
        .{ .name = "xl/worksheets/sheet1.xml", .data = &big, .deflate = true },
    } });
    defer testing.allocator.free(bytes);

    // Every prefix of the file.
    var len: usize = 0;
    while (len < bytes.len) : (len += if (len < 200 or len + 200 > bytes.len) 1 else 97) {
        try testing.expectError(error.InvalidZip, Archive.open(testing.allocator, bytes[0..len], .{}));
    }

    // Every byte flipped, one at a time: opening and reading either work or fail cleanly.
    const copy = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(copy);
    var failures: usize = 0;
    for (0..copy.len) |i| {
        if (i > 300 and i + 300 < copy.len and i % 13 != 0) continue;
        copy[i] ^= 0x5a;
        defer copy[i] ^= 0x5a;
        var archive = Archive.open(testing.allocator, copy, .{}) catch {
            failures += 1;
            continue;
        };
        defer archive.deinit();
        for (archive.entries) |*entry| {
            const content = archive.readAll(testing.allocator, entry, 1 << 20) catch {
                failures += 1;
                continue;
            };
            testing.allocator.free(content);
        }
    }
    try testing.expect(failures > 100);
}

test "running out of memory while opening or reading leaks nothing" {
    const Run = struct {
        fn run(gpa: std.mem.Allocator, bytes: []const u8) !void {
            var archive = try Archive.open(gpa, bytes, .{});
            defer archive.deinit();
            const content = try archive.readAll(gpa, &archive.entries[1], 1 << 20);
            gpa.free(content);
        }
    };
    const bytes = try buildTestZip(.{ .entries = &.{
        .{ .name = "a.xml", .data = "stored" },
        .{ .name = "b.xml", .data = "deflated deflated deflated deflated", .deflate = true },
    } });
    defer testing.allocator.free(bytes);
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{bytes});
}
