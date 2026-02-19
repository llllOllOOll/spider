const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const web = @import("web.zig");
const buffer_pool = @import("buffer_pool.zig");

const index_html = @embedFile("index.html");

const MAX_BODY_SIZE: u64 = 1 * 1024 * 1024;

const WORKER_COUNT = 8;
const ARENA_SIZE = 256 * 1024; // 256KB per worker

const ArenaPool = struct {
    arenas: [WORKER_COUNT]std.heap.ArenaAllocator,
    available: [WORKER_COUNT]std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator) ArenaPool {
        var pool: ArenaPool = undefined;
        for (0..WORKER_COUNT) |i| {
            pool.arenas[i] = std.heap.ArenaAllocator.init(allocator);
            pool.available[i] = std.atomic.Value(bool).init(true);
        }
        return pool;
    }

    pub fn acquire(self: *ArenaPool) ?*std.heap.ArenaAllocator {
        for (0..WORKER_COUNT) |i| {
            if (self.available[i].cmpxchgWeak(true, false, .acquire, .monotonic) == null) {
                return &self.arenas[i];
            }
        }
        return null;
    }

    pub fn release(self: *ArenaPool, arena: *std.heap.ArenaAllocator) void {
        _ = arena.reset(.retain_capacity);
        for (0..WORKER_COUNT) |i| {
            if (&self.arenas[i] == arena) {
                self.available[i].store(true, .release);
                return;
            }
        }
    }
};

const ConnectionContext = struct {
    stream: net.Stream,
    io: Io,
    allocator: std.mem.Allocator,
    router: *std.StringHashMap(HandlerFn),
    static_dir: []const u8,
    app: ?*web.App,
    buffer_pool: *buffer_pool.BufferPool,
    arena_pool: *ArenaPool,
};

const HandlerFn = *const fn (req: *std.http.Server.Request, allocator: std.mem.Allocator) anyerror!void;

pub const Server = struct {
    io: Io,
    listener: net.Server,
    allocator: std.mem.Allocator,
    router: std.StringHashMap(HandlerFn),
    static_dir: []const u8,
    app: ?*web.App,
    buffer_pool: buffer_pool.BufferPool,
    arena_pool: ArenaPool,

    pub fn init(allocator: std.mem.Allocator, io: Io, port: u16, static_dir: []const u8) !*Server {
        const self = try allocator.create(Server);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .listener = try net.IpAddress.listen(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, io, .{ .reuse_address = true }),
            .router = std.StringHashMap(HandlerFn).init(allocator),
            .static_dir = static_dir,
            .app = null,
            .buffer_pool = try buffer_pool.BufferPool.init(allocator),
            .arena_pool = ArenaPool.init(allocator),
        };

        try self.router.put("/", indexHandler);
        try self.router.put("/metric", metricHandler);

        return self;
    }

    pub fn deinit(self: *Server) void {
        self.router.deinit();
        self.listener.deinit(self.io);
        self.buffer_pool.deinit();
        for (0..WORKER_COUNT) |i| self.arena_pool.arenas[i].deinit();
        self.allocator.destroy(self);
    }

    pub fn setApp(self: *Server, app: *web.App) void {
        self.app = app;
    }

    pub fn start(self: *Server) !void {
        std.debug.print("Server listening on port 8080 (Io.Group + concurrent)\n", .{});
        var group: std.Io.Group = .init;
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
                .static_dir = self.static_dir,
                .app = self.app,
                .buffer_pool = &self.buffer_pool,
                .arena_pool = &self.arena_pool,
            };

            group.concurrent(self.io, handleConnection, .{ctx}) catch |err| {
                std.debug.print("Concurrent error: {}\n", .{err});
                stream.close(self.io);
                self.allocator.destroy(ctx);
            };
        }
    }
};

fn handleConnection(ctx: *ConnectionContext) void {
    defer {
        ctx.stream.close(ctx.io);
        ctx.allocator.destroy(ctx);
    }

    const arena = ctx.arena_pool.acquire() orelse {
        std.debug.print("Arena pool exhausted, falling back\n", .{});
        var fallback_arena = std.heap.ArenaAllocator.init(ctx.allocator);
        defer fallback_arena.deinit();
        return handleConnectionWithArena(ctx, &fallback_arena);
    };
    defer ctx.arena_pool.release(arena);

    handleConnectionWithArena(ctx, arena);
}

fn handleConnectionWithArena(ctx: *ConnectionContext, arena: *std.heap.ArenaAllocator) void {
    var small_buf: [4096]u8 = undefined;
    var large_buf: ?[]u8 = null;
    defer if (large_buf) |buf| ctx.buffer_pool.release(ctx.io, buf);

    var write_buffer: [4096]u8 = undefined;

    var stream_reader = net.Stream.Reader.init(ctx.stream, ctx.io, &small_buf);
    var stream_writer = net.Stream.Writer.init(ctx.stream, ctx.io, &write_buffer);

    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    while (true) {
        _ = arena.reset(.retain_capacity);

        var request = http_server.receiveHead() catch {
            break;
        };

        if (request.head.content_length) |len| {
            if (len > MAX_BODY_SIZE) {
                payloadTooLargeHandler(&request, arena.allocator()) catch {};
                break;
            }
            if (len > small_buf.len and large_buf == null) {
                large_buf = ctx.buffer_pool.acquire(ctx.io);
                if (large_buf) |buf| {
                    stream_reader = net.Stream.Reader.init(ctx.stream, ctx.io, buf);
                }
            }
        }

        const allocator = arena.allocator();
        const path = request.head.target;

        // Try web.App dispatch first
        if (ctx.app) |app| {
            // Build web.Request directly from already-parsed std.http data
            // No re-parsing needed - zero extra allocations
            const url = request.head.target;
            var web_req = web.Request{
                .method = switch (request.head.method) {
                    .GET => .get,
                    .POST => .post,
                    .PUT => .put,
                    .PATCH => .patch,
                    .DELETE => .delete,
                    .OPTIONS => .options,
                    .HEAD => .head,
                    else => .get,
                },
                .path = if (std.mem.indexOfScalar(u8, url, '?')) |q| url[0..q] else url,
                .query = if (std.mem.indexOfScalar(u8, url, '?')) |q| url[q + 1 ..] else null,
                .headers = web.Headers.init(),
                .body = null,
                .params = .{},
            };

            const web_res = app.dispatch(allocator, &web_req) catch {
                break;
            };

            var extra_headers: [16]std.http.Header = undefined;
            var header_count: usize = 0;
            var hit = web_res.headers.map.iterator();
            while (hit.next()) |entry| {
                if (header_count < 16) {
                    extra_headers[header_count] = .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* };
                    header_count += 1;
                }
            }

            request.respond(web_res.body orelse "", .{
                .status = @enumFromInt(@intFromEnum(web_res.status)),
                .extra_headers = extra_headers[0..header_count],
            }) catch break;
        } else {
            const handler = ctx.router.get(path);
            if (handler) |h| {
                h(&request, allocator) catch break;
            } else {
                staticFileHandler(&request, allocator, ctx.static_dir, ctx.io) catch break;
            }
        }

        if (!request.head.keep_alive) break;
    }
}

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

fn payloadTooLargeHandler(req: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
    _ = allocator;
    try req.respond("413 Payload Too Large", .{
        .status = .payload_too_large,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
    });
}

fn getMimeType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".gif")) return "image/gif";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
    if (std.mem.endsWith(u8, path, ".txt")) return "text/plain";
    if (std.mem.endsWith(u8, path, ".xml")) return "application/xml";
    return "application/octet-stream";
}

fn staticFileHandler(req: *std.http.Server.Request, allocator: std.mem.Allocator, static_dir: []const u8, io: Io) !void {
    const path = req.head.target;

    if (std.mem.indexOf(u8, path, "..") != null) {
        try notFoundHandler(req, allocator);
        return;
    }

    const full_path = try std.fs.path.join(allocator, &.{ static_dir, path });
    defer allocator.free(full_path);

    const file_content = std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .unlimited) catch {
        try notFoundHandler(req, allocator);
        return;
    };
    defer allocator.free(file_content);

    const content_type = getMimeType(full_path);

    try req.respond(file_content, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = content_type }},
    });
}

pub fn start(allocator: std.mem.Allocator, io: std.Io) !void {
    var server = try Server.init(allocator, io, 8080, "src/static");
    defer server.deinit();
    try server.start();
}
