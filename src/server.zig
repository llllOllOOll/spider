const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

fn indexHandler(req: *std.http.Server.Request) !void {
    try req.respond("<!DOCTYPE html><html><head><title>Welcome</title></head><body><h1>Welcome to Zig!</h1></body></html>", .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html" },
        },
    });
}

fn metricHandler(req: *std.http.Server.Request) !void {
    try req.respond("<div x-data=\"{ count: 0 }\"><button @click=\"count++\">Increment</button><span x-text=\"count\"></span></div>", .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html" },
        },
    });
}

fn notFoundHandler(req: *std.http.Server.Request) !void {
    try req.respond("404 Not Found", .{
        .status = .not_found,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain" },
        },
    });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const port: u16 = 8080;
    const address = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
    var listener = try net.IpAddress.listen(address, io, .{});
    defer listener.deinit(io);

    std.debug.print("Server listening on port {}\n", .{port});

    while (true) {
        const stream = listener.accept(io) catch |err| {
            std.debug.print("Accept error: {}\n", .{err});
            continue;
        };
        defer stream.close(io);

        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;

        var stream_reader = net.Stream.Reader.init(stream, io, &read_buffer);
        var stream_writer = net.Stream.Writer.init(stream, io, &write_buffer);

        var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

        var request = http_server.receiveHead() catch {
            continue;
        };

        const path = request.head.target;

        if (std.mem.eql(u8, path, "/")) {
            try indexHandler(&request);
        } else if (std.mem.eql(u8, path, "/metric")) {
            try metricHandler(&request);
        } else {
            try notFoundHandler(&request);
        }
    }
}
