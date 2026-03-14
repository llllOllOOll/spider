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
    _ = io;

    var args = std.ArrayList([]const u8).init(alloc);
    defer args.deinit();

    try args.append("curl");
    try args.append("-s");
    try args.append(url);

    for (headers) |h| {
        try args.append("-H");
        try args.append(try std.fmt.allocPrint(alloc, "{s}: {s}", .{ h.name, h.value }));
    }

    var child = std.process.Child.init(args.items, alloc);
    child.stdout_behavior = .pipe;

    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(alloc, 1024 * 1024);
    _ = try child.wait();
    return stdout;
}

pub fn post(
    alloc: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    body_content: []const u8,
    content_type: []const u8,
) ![]u8 {
    _ = io;

    var args = std.ArrayList([]const u8).init(alloc);
    defer args.deinit();

    try args.append("curl");
    try args.append("-s");
    try args.append("-X");
    try args.append("POST");
    try args.append("-H");
    try args.append(try std.fmt.allocPrint(alloc, "Content-Type: {s}", .{content_type}));
    try args.append("-d");
    try args.append(body_content);
    try args.append(url);

    var child = std.process.Child.init(args.items, alloc);
    child.stdout_behavior = .pipe;

    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(alloc, 1024 * 1024);
    _ = try child.wait();
    return stdout;
}
