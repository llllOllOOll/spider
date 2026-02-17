const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const Thread = std.Thread;

const index_html = @embedFile("index.html");

const ConnectionContext = struct {
    stream: net.Stream,
    io: Io,
    allocator: std.mem.Allocator,
    router: *std.StringHashMap(HandlerFn),
};

const HandlerFn = *const fn (req: *std.http.Server.Request, allocator: std.mem.Allocator) anyerror!void;

pub const Server = struct {
    io: Io,
    listener: net.Server,
    allocator: std.mem.Allocator,
    router: std.StringHashMap(HandlerFn),

    pub fn init(allocator: std.mem.Allocator, io: Io, port: u16) !*Server {
        const self = try allocator.create(Server);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .listener = try net.IpAddress.listen(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, io, .{}),
            .router = std.StringHashMap(HandlerFn).init(allocator),
        };

        try self.router.put("/", indexHandler);
        try self.router.put("/metric", metricHandler);

        return self;
    }

    pub fn deinit(self: *Server) void {
        self.router.deinit();
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

            const ctx = try self.allocator.create(ConnectionContext);
            ctx.* = .{
                .stream = stream,
                .io = self.io,
                .allocator = self.allocator,
                .router = &self.router,
            };

            _ = Thread.spawn(.{}, handleConnection, .{ctx}) catch |err| {
                std.debug.print("Thread spawn error: {}\n", .{err});
                stream.close(self.io);
                self.allocator.destroy(ctx);
            };
        }
    }
};

fn indexHandler(req: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
    _ = allocator;
    try req.respond(index_html, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html" }},
    });
}

fn metricHandler(req: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
    _ = allocator;
    try req.respond("<div x-data=\"{ count: 0 }\"><button @click=\"count++\">Increment</button><span x-text=\"count\"></span></div>", .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html" }},
    });
}

fn notFoundHandler(req: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
    _ = allocator;
    try req.respond("404 Not Found", .{
        .status = .not_found,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
    });
}

fn handleConnection(ctx: *ConnectionContext) void {
    defer {
        ctx.stream.close(ctx.io);
        ctx.allocator.destroy(ctx);
    }

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;

    var stream_reader = net.Stream.Reader.init(ctx.stream, ctx.io, &read_buffer);
    var stream_writer = net.Stream.Writer.init(ctx.stream, ctx.io, &write_buffer);

    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    var arena_allocator = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_allocator.deinit();

    while (true) {
        _ = arena_allocator.reset(.free_all);

        var request = http_server.receiveHead() catch break;
        const arena = arena_allocator.allocator();

        const path = request.head.target;

        const handler = ctx.router.get(path) orelse notFoundHandler;
        handler(&request, arena) catch break;

        if (!request.head.keep_alive) break;
    }
}

pub fn start(init: std.process.Init) !void {
    var server = try Server.init(init.arena.allocator(), init.io, 8080);
    defer server.deinit();
    try server.start();
}
