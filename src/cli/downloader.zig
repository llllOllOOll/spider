const std = @import("std");
const http = std.http;
const fs_utils = @import("fs_utils.zig");
const checksums = @import("checksums.zig");

/// Downloads `url` into `dir/filename`, after checking its SHA-256 against
/// src/cli/checksums.zig. A file that does not match is not written.
pub fn download(io: std.Io, allocator: std.mem.Allocator, url: []const u8, dir: std.Io.Dir, filename: []const u8) !void {
    std.debug.print("  Downloading {s}...\n", .{filename});
    const body = try fetch(io, allocator, url);
    defer allocator.free(body);
    try writeChecked(io, dir, filename, url, body, checksums.expected(url));
    std.debug.print("  Downloaded {s} ({d} bytes, SHA-256 ok)\n", .{ filename, body.len });
}

/// `fetch`, with the body checked against src/cli/checksums.zig.
pub fn fetchVerified(io: std.Io, allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const body = try fetch(io, allocator, url);
    errdefer allocator.free(body);
    try checksums.verify(url, body);
    return body;
}

/// Writes `body` only when its SHA-256 is `expected_hex`.
fn writeChecked(io: std.Io, dir: std.Io.Dir, filename: []const u8, url: []const u8, body: []const u8, expected_hex: ?[]const u8) !void {
    checksums.verifyHex(expected_hex, url, body) catch |err| {
        std.debug.print("  {s} was not written\n", .{filename});
        return err;
    };
    try fs_utils.writeFile(io, dir, filename, body);
}

/// The body of `url` (redirects followed), owned by the caller.
pub fn fetch(io: std.Io, allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var client = http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var req = try client.request(.GET, uri, .{});
    defer req.deinit();
    try req.sendBodiless();

    // 16KB aux buffer allows following GitHub-style long redirect URLs
    var aux_buf: [16384]u8 = undefined;
    var response = try req.receiveHead(aux_buf[0..]);

    if (response.head.status != .ok) {
        std.debug.print("error: HTTP {d} for {s}\n", .{ @backingInt(response.head.status), url });
        return error.HttpError;
    }

    var transfer_buf: [4096]u8 = undefined;
    var decompress: http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);

    var body = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 4096);
    errdefer body.deinit(allocator);

    while (true) {
        var chunk: [4096]u8 = undefined;
        const n = reader.*.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        try body.appendSlice(allocator, chunk[0..n]);
    }
    return body.toOwnedSlice(allocator);
}

test "writeChecked: a matching body is written, a wrong one is refused and nothing is written" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const abc_hex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    try writeChecked(io, tmp.dir, "bin/good", "https://example.test/good", "abc", abc_hex);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("abc", try tmp.dir.readFile(io, "bin/good", &buf));

    try std.testing.expectError(error.ChecksumMismatch, writeChecked(io, tmp.dir, "bin/bad", "https://example.test/bad", "tampered", abc_hex));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "bin/bad", .{}));

    try std.testing.expectError(error.ChecksumUnknown, writeChecked(io, tmp.dir, "bin/unknown", "https://example.test/unknown", "abc", null));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "bin/unknown", .{}));
}
