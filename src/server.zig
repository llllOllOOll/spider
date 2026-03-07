// TODO: Native TLS support (v0.3.0)
// Currently: deploy behind nginx/caddy for HTTPS
// Reference: BoringSSL or OpenSSL via C bindings

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const web = @import("web.zig");
const websocket = @import("websocket.zig");
const spider = @import("spider.zig");
const logger = @import("logger.zig");
const metrics = @import("metrics.zig");

const log = logger.Logger.init(.info);

const index_html = @embedFile("index.html");

const MAX_BODY_SIZE: u64 = 1 * 1024 * 1024;
const RETAIN_BYTES: usize = 8192;
const SLOW_REQUEST_THRESHOLD_NS: u64 = 500 * 1000 * 1000; // 500ms in nanoseconds

var shutdown_flag = std.atomic.Value(bool).init(false);
var ws_counter = std.atomic.Value(u64).init(0);

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
    port: u16,

    pub fn init(allocator: std.mem.Allocator, io: Io, host: []const u8, port: u16, static_dir: []const u8) !*Server {
        const self = try allocator.create(Server);

        const address = if (std.mem.eql(u8, host, "0.0.0.0") or std.mem.eql(u8, host, "*"))
            net.IpAddress{ .ip4 = net.Ip4Address.unspecified(port) }
        else
            net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };

        self.* = .{
            .io = io,
            .allocator = allocator,
            .listener = try net.IpAddress.listen(address, io, .{ .reuse_address = true }),
            .router = std.StringHashMap(HandlerFn).init(allocator),
            .static_dir = static_dir,
            .app = null,
            .port = port,
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
        metrics.initMetrics(self.io);
        log.info("server_started", .{ .port = self.port, .mode = "Io.Group + concurrent" });
        var group: std.Io.Group = .init;
        while (true) {
            if (shutdown_flag.load(.acquire)) {
                break;
            }
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

fn handleConnection(ctx: *ConnectionContext) error{Canceled}!void {
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

        var request = http_server.receiveHead() catch |err| {
            std.debug.print("SERVER: receiveHead error: {}\n", .{err});
            break;
        };

        const arena = ctx.req_arena.allocator();
        const method = @tagName(request.head.method);
        // Copy path to persistent memory since request.head.target may point to buffer that gets overwritten
        const path = ctx.allocator.dupe(u8, request.head.target) catch |err| {
            std.debug.print("ERROR: dupe failed: {}\n", .{err});
            break;
        };
        defer ctx.allocator.free(path);
        std.debug.print("SERVER: Received {s} {s}\n", .{ method, path });

        const target = path;
        const is_ws = std.mem.startsWith(u8, target, "/ws");
        if (is_ws and request.head.method == .GET) {
            var ws = websocket.Server.init(ctx.stream, ctx.io, ctx.allocator);

            // Parse WebSocket headers from request head_buffer
            var ws_headers = web.Headers.init();
            var header_iter = request.iterateHeaders();
            while (header_iter.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "upgrade")) {
                    ws_headers.set(ctx.allocator, "upgrade", header.value) catch {};
                } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-key")) {
                    ws_headers.set(ctx.allocator, "sec-websocket-key", header.value) catch {};
                } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-version")) {
                    ws_headers.set(ctx.allocator, "sec-websocket-version", header.value) catch {};
                }
            }

            const handshake_ok = ws.handshake(ctx.allocator, &ws_headers) catch false;
            if (handshake_ok) {
                const conn_id = ws_counter.fetchAdd(1, .monotonic);
                const hub = spider.getWsHub();
                hub.add(.{ .id = conn_id, .stream = ctx.stream }) catch {};

                metrics.global_metrics.setWsClients(hub.count());

                // Broadcast client count
                var count_buf: [64]u8 = undefined;
                const count_msg = std.fmt.bufPrint(&count_buf, "{{\"type\":\"client_count\",\"count\":{}}}", .{hub.count()}) catch "{\"type\":\"client_count\",\"count\":0}";
                hub.broadcast(count_msg);

                // Echo loop
                while (true) {
                    const frame = ws.readFrame(arena) catch break;
                    if (frame == null) break;
                    switch (frame.?.opcode) {
                        .text => {
                            // Broadcast to all
                            hub.broadcast(frame.?.payload);
                        },
                        .binary => ws.writeFrame(.binary, frame.?.payload) catch break,
                        .ping => ws.sendPong(frame.?.payload) catch break,
                        .close => {
                            ws.sendClose(1000) catch break;
                            break;
                        },
                        else => {},
                    }
                }

                // Remove from hub on disconnect
                hub.remove(conn_id);
                metrics.global_metrics.setWsClients(hub.count());
                var leave_buf: [64]u8 = undefined;
                const leave_msg = std.fmt.bufPrint(&leave_buf, "{{\"type\":\"client_count\",\"count\":{}}}", .{hub.count()}) catch "{\"type\":\"client_count\",\"count\":0}";
                hub.broadcast(leave_msg);
            }
            break;
        }

        // Check for WebSocket upgrade - try handshake, if it succeeds handle WS
        if (ctx.app) |app| {

            // Use the copied path instead of request.head.target
            const url = target;
            const web_method: web.Method = switch (request.head.method) {
                .GET => web.Method.get,
                .POST => web.Method.post,
                .PUT => web.Method.put,
                .PATCH => web.Method.patch,
                .DELETE => web.Method.delete,
                .OPTIONS => web.Method.options,
                .HEAD => web.Method.head,
                else => web.Method.get,
            };

            // Read body if present
            var body: ?[]const u8 = null;
            if (request.head.content_length) |len| {
                std.debug.print("SERVER: content_length = {}\n", .{len});
                if (len > 0 and len <= MAX_BODY_SIZE) {
                    const body_reader = request.readerExpectNone(&read_buffer);
                    body = body_reader.readAlloc(arena, @intCast(len)) catch |err| {
                        std.debug.print("SERVER: Error reading body: {}\n", .{err});
                        break;
                    };
                    std.debug.print("SERVER: Read body: {s}\n", .{body.?});
                }
            } else {
                std.debug.print("SERVER: No content_length header\n", .{});
            }

            var web_req = web.Request{
                .method = web_method,
                .path = if (std.mem.indexOfScalar(u8, url, '?')) |q| url[0..q] else url,
                .query = if (std.mem.indexOfScalar(u8, url, '?')) |q| url[q + 1 ..] else null,
                .headers = web.Headers.init(),
                .body = body,
                .params = .{},
            };

            const req_start_time = std.Io.Clock.now(.awake, ctx.io);

            if (body) |b| {
                metrics.global_metrics.addBytesIn(b.len);
            }

            var web_res = app.dispatch(arena, &web_req) catch |err| {
                std.debug.print("SERVER: dispatch error: {}\n", .{err});
                metrics.global_metrics.incrementError();
                break;
            };
            defer web_res.deinit();

            const req_end_time = std.Io.Clock.now(.awake, ctx.io);
            const req_duration = req_start_time.durationTo(req_end_time);
            if (req_duration.toNanoseconds() > SLOW_REQUEST_THRESHOLD_NS) {
                metrics.global_metrics.incrementSlowRequest();
            }

            if (web_res.body) |b| {
                metrics.global_metrics.addBytesOut(b.len);
            }

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
            }) catch {
                metrics.global_metrics.incrementError();
                break;
            };

            metrics.global_metrics.incrementRequest();
            log.request(@intFromEnum(web_res.status), 0, method, path);
        } else {
            const handler = ctx.router.get(target);
            if (handler) |h| {
                h(&request, arena) catch break;
            } else {
                staticFileHandler(&request, arena, ctx.static_dir, ctx.io) catch break;
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

fn staticFileHandler(req: *std.http.Server.Request, allocator: std.mem.Allocator, static_dir: []const u8, io: Io) !void {
    // Remove leading slash from request path
    const req_path = if (std.mem.startsWith(u8, req.head.target, "/")) req.head.target[1..] else req.head.target;

    // Join static_dir with request path
    const full_path = std.fs.path.join(allocator, &.{ static_dir, req_path }) catch |err| {
        std.debug.print("SERVER: path join error: {}\n", .{err});
        try notFoundHandler(req, allocator);
        return;
    };
    defer allocator.free(full_path);

    // Read file
    const content = std.Io.Dir.cwd().readFileAlloc(
        io,
        full_path,
        allocator,
        .limited(10 * 1024 * 1024),
    ) catch |err| {
        std.debug.print("SERVER: file read error: {}\n", .{err});
        try notFoundHandler(req, allocator);
        return;
    };
    defer allocator.free(content);

    // Determine MIME type
    const content_type = blk: {
        if (std.mem.endsWith(u8, req_path, ".png")) break :blk "image/png";
        if (std.mem.endsWith(u8, req_path, ".jpg") or std.mem.endsWith(u8, req_path, ".jpeg")) break :blk "image/jpeg";
        if (std.mem.endsWith(u8, req_path, ".svg")) break :blk "image/svg+xml";
        if (std.mem.endsWith(u8, req_path, ".css")) break :blk "text/css";
        if (std.mem.endsWith(u8, req_path, ".js")) break :blk "application/javascript";
        if (std.mem.endsWith(u8, req_path, ".ico")) break :blk "image/x-icon";
        if (std.mem.endsWith(u8, req_path, ".html")) break :blk "text/html";
        if (std.mem.endsWith(u8, req_path, ".woff2")) break :blk "font/woff2";
        break :blk "application/octet-stream";
    };

    try req.respond(content, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = content_type }},
    });
}
