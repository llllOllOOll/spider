const std = @import("std");
const http = std.http;
const fs_utils = @import("fs_utils.zig");

pub fn download(io: std.Io, allocator: std.mem.Allocator, url: []const u8, dir: std.Io.Dir, filename: []const u8) !void {
    std.debug.print("  Downloading {s}...\n", .{filename});

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
        std.debug.print("error: HTTP {d} for {s}\n", .{ @intFromEnum(response.head.status), url });
        return error.HttpError;
    }

    var transfer_buf: [4096]u8 = undefined;
    var decompress: http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);

    var body = std.ArrayList(u8).initCapacity(allocator, 4096) catch unreachable;
    defer body.deinit(allocator);

    while (true) {
        var chunk: [4096]u8 = undefined;
        const n = reader.*.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        try body.appendSlice(allocator, chunk[0..n]);
    }

    try fs_utils.writeFile(io, dir, filename, body.items);
    std.debug.print("  Downloaded {s} ({d} bytes)\n", .{ filename, body.items.len });
}
