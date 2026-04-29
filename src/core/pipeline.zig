const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const web = @import("../web.zig");
const websocket = @import("../ws/websocket.zig");
const spider = @import("../spider.zig");
const logger = @import("../internal/logger.zig");
const metrics = @import("../internal/metrics.zig");
const server_core = @import("server.zig");

const ConnectionContext = server_core.ConnectionContext;
const MAX_BODY_SIZE = server_core.MAX_BODY_SIZE;
const RETAIN_BYTES = server_core.RETAIN_BYTES;
const SLOW_REQUEST_THRESHOLD_NS = server_core.SLOW_REQUEST_THRESHOLD_NS;
const active_connections = server_core.active_connections;
const ws_counter = server_core.ws_counter;
const shutdown_flag = server_core.shutdown_flag;

const log = logger.Logger.init(.info);

const index_html = @embedFile("../index.html");

pub fn handleConnection(ctx: *ConnectionContext) error{Canceled}!void {
    _ = active_connections.fetchAdd(1, .monotonic);
    defer {
        _ = active_connections.fetchSub(1, .monotonic);
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
            if (err != error.HttpConnectionClosing) {
                std.debug.print("SERVER: receiveHead error: {}\n", .{err});
            }
            break;
        };

        const arena = ctx.req_arena.allocator();
        const method = @tagName(request.head.method);
        const path = arena.dupe(u8, request.head.target) catch |err| {
            std.debug.print("ERROR: dupe failed: {}\n", .{err});
            break;
        };
        std.debug.print("SERVER: Received {s} {s}\n", .{ method, path });

        const target = path;
        const is_ws = std.mem.startsWith(u8, target, "/ws");
        if (is_ws and request.head.method == .GET) {
            var ws = websocket.Server.init(ctx.stream, ctx.io, ctx.allocator);

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

                var count_buf: [64]u8 = undefined;
                const count_msg = std.fmt.bufPrint(&count_buf, "{\"type\":\"client_count\",\"count\":{}}", .{hub.count()}) catch "{\"type\":\"client_count\",\"count\":0}";
                hub.broadcast(count_msg);

                while (true) {
                    const frame = ws.readFrame(arena) catch break;
                    if (frame == null) break;
                    switch (frame.?.opcode) {
                        .text => {
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

                hub.remove(conn_id);
                metrics.global_metrics.setWsClients(hub.count());
                var leave_buf: [64]u8 = undefined;
                const leave_msg = std.fmt.bufPrint(&leave_buf, "{\"type\":\"client_count\",\"count\":{}}", .{hub.count()}) catch "{\"type\":\"client_count\",\"count\":0}";
                hub.broadcast(leave_msg);
            }
            break;
        }

        if (ctx.app) |app| {
            const url = target;
            const web_method: web.Method = switch (request.head.method) {
                .GET => web.Method.get,
                .POST => web.Method.post,
                .PUT => web.Method.put,
                .PATCH => web.Method.patch,
                .DELETE => web.Method.delete,
                .OPTIONS => web.Method.options,
                .HEAD => web.Method.head,
                else => {
                    request.respond("405 Method Not Allowed", .{
                        .status = .method_not_allowed,
                        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
                    }) catch {};
                    return;
                },
            };

            var web_req = web.Request{
                .method = web_method,
                .path = if (std.mem.indexOfScalar(u8, url, '?')) |q| url[0..q] else url,
                .query = if (std.mem.indexOfScalar(u8, url, '?')) |q| url[q + 1 ..] else null,
                .headers = web.Headers.init(),
                .body = null,
                .params = .{},
                .io = ctx.io,
            };
            var req_header_iter = request.iterateHeaders();
            while (req_header_iter.next()) |header| {
                web_req.headers.set(arena, header.name, header.value) catch {};
            }
            var body: ?[]const u8 = null;
            if (request.head.content_length) |len| {
                if (len > 0 and len <= MAX_BODY_SIZE) {
                    const body_buffer = arena.alloc(u8, @intCast(len)) catch break;
                    const body_reader = request.readerExpectNone(body_buffer);
                    body = body_reader.readAlloc(arena, @intCast(len)) catch |err| {
                        std.debug.print("SERVER: Error reading body: {}\n", .{err});
                        break;
                    };
                }
            }
            web_req.body = body;
            defer web_req.deinit(arena);

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

            var extra_headers: [17]std.http.Header = undefined;
            var header_count: usize = 0;
            var hit = web_res.headers.map.iterator();
            while (hit.next()) |entry| {
                if (header_count < 16) {
                    extra_headers[header_count] = .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* };
                    header_count += 1;
                }
            }

            const has_request_body_info = request.head.content_length != null or request.head.transfer_encoding != .none;

            if (web_res.status == .not_found) {
                const target_len = request.head.target.len;
                if (target_len > 0 and target_len < 4096) {
                    const static_dir = if (ctx.static_dir.len > 0) ctx.static_dir else "public";
                    staticFileHandler(&request, arena, static_dir, ctx.io) catch {
                        metrics.global_metrics.incrementError();
                    };
                } else {
                    notFoundHandler(&request, arena) catch {};
                }
            } else {
                const should_close = !has_request_body_info;
                if (should_close) {
                    if (header_count < 17) {
                        extra_headers[header_count] = .{ .name = "Connection", .value = "close" };
                        header_count += 1;
                    }
                }
                request.respond(web_res.body orelse "", .{
                    .status = @enumFromInt(@intFromEnum(web_res.status)),
                    .extra_headers = extra_headers[0..header_count],
                    .keep_alive = has_request_body_info,
                }) catch {
                    metrics.global_metrics.incrementError();
                    break;
                };
            }

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

pub fn indexHandler(req: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
    _ = allocator;
    try req.respond(index_html, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html" }},
    });
}

pub fn metricHandler(req: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
    _ = allocator;
    try req.respond("<div x-data=\"{ count: 0 }\"><button @click=\"count++\">Increment</button><span x-text=\"count\"></span></div>", .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html" }},
    });
}

pub fn healthHandler(req: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
    _ = allocator;
    try req.respond("{\"status\":\"ok\",\"version\":\"0.1.0\"}", .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

pub fn notFoundHandler(req: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
    _ = allocator;
    try req.respond("404 Not Found", .{
        .status = .not_found,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
    });
}

pub fn payloadTooLargeHandler(req: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
    _ = allocator;
    try req.respond("413 Payload Too Large", .{
        .status = .payload_too_large,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
    });
}

pub fn staticFileHandler(req: *std.http.Server.Request, allocator: std.mem.Allocator, static_dir: []const u8, io: Io) !void {
    const raw_target = req.head.target;

    if (raw_target.len == 0) {
        try notFoundHandler(req, allocator);
        return;
    }

    const target = allocator.dupe(u8, raw_target) catch {
        try notFoundHandler(req, allocator);
        return;
    };
    defer allocator.free(target);

    const req_path = if (std.mem.startsWith(u8, target, "/")) target[1..] else target;

    if (std.mem.indexOf(u8, req_path, "..")) |_| {
        try notFoundHandler(req, allocator);
        return;
    }

    const full_path = std.fs.path.join(allocator, &.{ static_dir, req_path }) catch |err| {
        std.debug.print("SERVER: path join error: {}\n", .{err});
        try notFoundHandler(req, allocator);
        return;
    };
    defer allocator.free(full_path);

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
