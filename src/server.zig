const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

pub const Server = struct {
    io: Io,
    listener: net.Server,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, io: Io, port: u16) !*Server {
        const self = try allocator.create(Server);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .listener = try net.IpAddress.listen(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, io, .{}),
        };
        return self;
    }

    pub fn deinit(self: *Server) void {
        self.listener.deinit(self.io);
        self.allocator.destroy(self);
    }

    pub fn start(self: *Server) !void {
        std.debug.print("Server listening on port 8080\n", .{});
        while (true) {
            const stream = self.listener.accept(self.io) catch |err| {
                std.debug.print("Accept error: {}\n", .{err});
                continue;
            };
            self.handleConnection(stream) catch |err| {
                std.debug.print("Request error: {}\n", .{err});
            };
        }
    }

    fn handleConnection(self: *Server, stream: net.Stream) !void {
        defer stream.close(self.io);

        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;

        var stream_reader = net.Stream.Reader.init(stream, self.io, &read_buffer);
        var stream_writer = net.Stream.Writer.init(stream, self.io, &write_buffer);

        var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

        var arena_allocator = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_allocator.deinit();

        while (true) {
            _ = arena_allocator.reset(.free_all);

            var request = http_server.receiveHead() catch break;
            const arena = arena_allocator.allocator();

            const path = request.head.target;

            if (std.mem.eql(u8, path, "/")) {
                try self.indexHandler(&request, arena);
            } else if (std.mem.eql(u8, path, "/metric")) {
                try self.metricHandler(&request, arena);
            } else {
                try self.notFoundHandler(&request, arena);
            }

            if (!request.head.keep_alive) break;
        }
    }

    fn indexHandler(self: *Server, req: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
        _ = self;
        _ = allocator;
        try req.respond("<!DOCTYPE html><html><head><title>Welcome</title></head><body><h1>Welcome to Zig!</h1></body></html>", .{
            .status = .ok,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html" }},
        });
    }

    fn metricHandler(self: *Server, req: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
        _ = self;
        _ = allocator;
        try req.respond("<div x-data=\"{ count: 0 }\"><button @click=\"count++\">Increment</button><span x-text=\"count\"></span></div>", .{
            .status = .ok,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html" }},
        });
    }

    fn notFoundHandler(self: *Server, req: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
        _ = self;
        _ = allocator;
        try req.respond("404 Not Found", .{
            .status = .not_found,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
    }
};

pub fn start(init: std.process.Init) !void {
    var server = try Server.init(init.arena.allocator(), init.io, 8080);
    defer server.deinit();
    try server.start();
}
