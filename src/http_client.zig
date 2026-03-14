const std = @import("std");

pub const HttpError = error{ RequestFailed, BadStatus };

pub const Header = std.http.Header;

fn readBody(alloc: std.mem.Allocator, response: *std.http.Client.Response, transfer_buffer: []u8, decompress_buffer: []u8) ![]u8 {
    var decompress: std.http.Decompress = undefined;
    var body_reader = response.readerDecompressing(transfer_buffer, &decompress, decompress_buffer);

    var body = try std.ArrayList(u8).initCapacity(alloc, 4096);
    errdefer body.deinit(alloc);

    while (true) {
        const byte = body_reader.takeByte() catch break;
        try body.append(alloc, byte);
    }

    return body.toOwnedSlice(alloc);
}

pub fn get(
    alloc: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    headers: []const Header,
) ![]u8 {
    var client = std.http.Client{ .allocator = alloc, .io = io };
    defer client.deinit();

    var req = try client.request(.GET, try std.Uri.parse(url), .{
        .extra_headers = headers,
    });
    defer req.deinit();

    try req.sendBodiless();

    var response = try req.receiveHead(&.{});

    if (response.head.status != .ok) {
        return HttpError.BadStatus;
    }

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try alloc.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try alloc.alloc(u8, std.compress.flate.max_window_len),
        .compress => return HttpError.RequestFailed,
    };
    defer if (decompress_buffer.len != 0) alloc.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    return readBody(alloc, &response, &transfer_buffer, decompress_buffer);
}

pub fn post(
    alloc: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    body_content: []const u8,
    content_type: []const u8,
) ![]u8 {
    var client = std.http.Client{ .allocator = alloc, .io = io };
    defer client.deinit();

    var req = try client.request(.POST, try std.Uri.parse(url), .{
        .headers = .{ .content_type = .{ .override = content_type } },
    });
    defer req.deinit();

    try req.sendBodyComplete(@constCast(body_content));

    var response = try req.receiveHead(&.{});

    if (response.head.status != .ok) {
        return HttpError.BadStatus;
    }

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try alloc.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try alloc.alloc(u8, std.compress.flate.max_window_len),
        .compress => return HttpError.RequestFailed,
    };
    defer if (decompress_buffer.len != 0) alloc.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    return readBody(alloc, &response, &transfer_buffer, decompress_buffer);
}
