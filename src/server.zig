// TODO: Native TLS support (v0.3.0)
// Currently: deploy behind nginx/caddy for HTTPS
// Reference: BoringSSL or OpenSSL via C bindings

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const web = @import("web.zig");
const logger = @import("logger.zig");

const log = logger.Logger.init(.info);

const index_html = @embedFile("index.html");

const MAX_BODY_SIZE: u64 = 1 * 1024 * 1024;
const RETAIN_BYTES: usize = 8192;

var shutdown_flag = std.atomic.Value(bool).init(false);

fn setupSignalHandlers() void {
    var act = std.posix.Sigaction{
        .handler = .{ .handler = &handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    shutdown_flag.store(true, .release);
}

const ConnectionContext = struct {
    stream: net.Stream,
    io: Io,
    allocator: std.mem.Allocator,
    router: *std.StringHashMap(HandlerFn),
    static_dir: []const u8,
    app: ?*web.App,
    conn_arena: *std.heap.ArenaAllocator,
    req_arena: *std.heap.ArenaAllocator,
};

const HandlerFn = *const fn (req: *std.http.Server.Request, allocator: std.mem.Allocator) anyerror!void;

pub const Server = struct {
    io: Io,
    listener: net.Server,
    allocator: std.mem.Allocator,
    router: std.StringHashMap(HandlerFn),
    static_dir: []const u8,
    app: ?*web.App,

    pub fn init(allocator: std.mem.Allocator, io: Io, port: u16, static_dir: []const u8) !*Server {
        const self = try allocator.create(Server);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .listener = try net.IpAddress.listen(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, io, .{ .reuse_address = true }),
            .router = std.StringHashMap(HandlerFn).init(allocator),
            .static_dir = static_dir,
            .app = null,
        };

        try self.router.put("/", indexHandler);
        try self.router.put("/metric", metricHandler);
        try self.router.put("/health", healthHandler);

        return self;
    }

    pub fn deinit(self: *Server) void {
        self.router.deinit();
        self.listener.deinit(self.io);
        self.allocator.destroy(self);
    }

    pub fn setApp(self: *Server, app: *web.App) void {
        self.app = app;
    }

    pub fn start(self: *Server) !void {
        setupSignalHandlers();
        log.info("server_started", .{ .port = 8080, .mode = "Io.Group + concurrent" });
        var group: std.Io.Group = .init;
        while (!shutdown_flag.load(.acquire)) {
            const stream = self.listener.accept(self.io) catch |err| {
                if (shutdown_flag.load(.acquire)) break;
                log.warn("accept_error", .{ .err = @errorName(err) });
                continue;
            };

            const ctx = try self.allocator.create(ConnectionContext);
            const conn_arena = try self.allocator.create(std.heap.ArenaAllocator);
            conn_arena.* = std.heap.ArenaAllocator.init(self.allocator);
            const req_arena = try self.allocator.create(std.heap.ArenaAllocator);
            req_arena.* = std.heap.ArenaAllocator.init(self.allocator);
            ctx.* = .{
                .stream = stream,
                .io = self.io,
                .allocator = self.allocator,
                .router = &self.router,
                .static_dir = self.static_dir,
                .app = self.app,
                .conn_arena = conn_arena,
                .req_arena = req_arena,
            };

            group.concurrent(self.io, handleConnection, .{ctx}) catch |err| {
                log.warn("concurrent_error", .{ .err = @errorName(err) });
                stream.close(self.io);
                self.allocator.destroy(ctx);
            };
        }
        log.info("shutting_down", .{});
    }
};

fn handleConnection(ctx: *ConnectionContext) void {
    defer {
        ctx.req_arena.deinit();
        ctx.conn_arena.deinit();
        ctx.allocator.destroy(ctx.req_arena);
        ctx.allocator.destroy(ctx.conn_arena);
        ctx.stream.close(ctx.io);
        ctx.allocator.destroy(ctx);
    }

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;

    var stream_reader = net.Stream.Reader.init(ctx.stream, ctx.io, &read_buffer);
    var stream_writer = net.Stream.Writer.init(ctx.stream, ctx.io, &write_buffer);

    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    while (true) {
        _ = ctx.req_arena.reset(.{ .retain_with_limit = RETAIN_BYTES });

        var request = http_server.receiveHead() catch {
            break;
        };

        const method = @tagName(request.head.method);
        const path = request.head.target;

        if (request.head.content_length) |len| {
            if (len > MAX_BODY_SIZE) {
                payloadTooLargeHandler(&request, ctx.req_arena.allocator()) catch {};
                break;
            }
        }

        const arena = ctx.req_arena.allocator();
        const target = request.head.target;

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

            const web_res = app.dispatch(arena, &web_req) catch {
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
            const handler = ctx.router.get(target);
            if (handler) |h| {
                h(&request, arena) catch break;
            } else {
                staticFileHandler(&request, arena, ctx.static_dir, ctx.io) catch break;
            }
        }

        log.debug("request", .{
            .method = method,
            .path = path,
        });

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

fn healthHandler(req: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
    _ = allocator;
    try req.respond("{\"status\":\"ok\",\"version\":\"0.1.0\"}", .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
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
