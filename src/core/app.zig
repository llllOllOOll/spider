const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const build_options = @import("spider_build_options");
const env = @import("../internal/env.zig");
const static_mod = @import("../modules/static.zig");
pub const StaticConfig = static_mod.StaticConfig;
pub const RouteConfig = struct {
    roles: []const []const u8 = &.{},
    org_roles: []const []const u8 = &.{},
};

const ctx_mod = @import("context.zig");
const Ctx = ctx_mod.Ctx;
const Response = ctx_mod.Response;
const MiddlewareFn = ctx_mod.MiddlewareFn;
const ErrorHandler = ctx_mod.ErrorHandler;
const ViewsConfig = ctx_mod.ViewsConfig;
const Database = @import("database.zig").Database;
const Router = @import("../routing/router.zig").Router;
const auth_marker = @import("../modules/auth_marker.zig");
/// Registered only with `env = .development`; declares no access on purpose
/// (see checkRouteAccess).
pub const livereload_path = "/_spider/reload";
const Handler = @import("../routing/router.zig").Handler;
const Route = @import("../routing/router.zig").Route;
const Group = @import("../routing/group.zig").Group;
const Config = @import("../internal/config.zig").Config;
const Env = @import("../internal/config.zig").Env;
const default_config = @import("../internal/config.zig").default;
const views_mod = @import("../render/views.zig");
const livereload = @import("../modules/livereload.zig");
const health_mod = @import("../modules/health.zig");
const Hub = @import("../ws/hub.zig").Hub;
const Ws = @import("../ws/ws.zig").Ws;
const sse_mod = @import("../ws/sse.zig");
const Sse = sse_mod.Sse;
const websocket = @import("../ws/websocket.zig");
const Watchdog = @import("watchdog.zig").Watchdog;
const handler_mod = @import("handler.zig");
const route_config = @import("../routing/route_config.zig");
const usesExtractors = handler_mod.usesExtractors;
const buildAutoWrapper = handler_mod.buildAutoWrapper;
const watchdog_mod = @import("watchdog.zig");
const rbac = @import("../modules/rbac.zig");

const WsRouteHub = struct {
    handler: Handler,
    hub: *Hub,
    threaded: std.Io.Threaded,
};

fn nextFn(c: *Ctx) anyerror!Response {
    if (c._chain_mws.len == 0) {
        return c._chain_handler.?(c);
    }
    const m = c._chain_mws[0];
    c._chain_mws = c._chain_mws[1..];
    return m(c, nextFn);
}

fn runChain(c: *Ctx, middlewares: []const MiddlewareFn, handler: Handler) anyerror!Response {
    c._chain_mws = middlewares;
    c._chain_handler = handler;
    return nextFn(c);
}

const PathMiddlewareEntry = struct {
    path: []const u8,
    middleware: MiddlewareFn,
};

fn collectMiddlewares(
    global_middlewares: []const MiddlewareFn,
    path_middlewares: []const PathMiddlewareEntry,
    path: []const u8,
    route_middlewares: []const MiddlewareFn,
    buf: []MiddlewareFn,
) usize {
    var count: usize = 0;

    for (global_middlewares) |m| {
        if (count < buf.len) {
            buf[count] = m;
            count += 1;
        }
    }

    for (path_middlewares) |entry| {
        const prefix = if (std.mem.endsWith(u8, entry.path, "*"))
            entry.path[0 .. entry.path.len - 1]
        else
            entry.path;
        if (std.mem.startsWith(u8, path, prefix)) {
            if (count < buf.len) {
                buf[count] = entry.middleware;
                count += 1;
            }
        }
    }

    for (route_middlewares) |m| {
        if (count < buf.len) {
            buf[count] = m;
            count += 1;
        }
    }

    return count;
}

const WorkerCtx = struct {
    io: Io,
    gpa: std.mem.Allocator,
    listener: *Io.net.Server,
    router: *Router,
    static_config: StaticConfig,
    views_index: ?*const views_mod.ViewsIndex,
    config: Config,
    error_handler: ?ErrorHandler,
    _db: ?*const Database,
    decorations: ?*const anyopaque,
    ws_route_hubs: []const WsRouteHub,
    sse_hub: ?*Hub,
    global_middlewares: []const MiddlewareFn,
    path_middlewares: []const PathMiddlewareEntry,
    watchdog: *Watchdog,
};

const ConnCtx = struct {
    stream: Io.net.Stream,
    io: Io,
    gpa: std.mem.Allocator,
    router: *Router,
    static_config: StaticConfig,
    views_index: ?*const views_mod.ViewsIndex,
    config: Config,
    error_handler: ?ErrorHandler,
    _db: ?*const Database,
    decorations: ?*const anyopaque,
    ws_route_hubs: []const WsRouteHub,
    sse_hub: ?*Hub,
    global_middlewares: []const MiddlewareFn,
    path_middlewares: []const PathMiddlewareEntry,
    watchdog: *Watchdog,
};

fn workerLoop(wctx: WorkerCtx) void {
    var group: std.Io.Group = .init;
    var failures: u32 = 0;

    while (true) {
        const stream = wctx.listener.accept(wctx.io) catch |err| switch (err) {
            // Shutdown: the only way out. Any other accept error leaves the
            // listener usable, and leaving the loop used to stop the server
            // for good while the process stayed up (one EMFILE burst was
            // enough on zio, which has a single accept loop).
            error.Canceled, error.SocketNotListening => break,
            error.ConnectionAborted, error.WouldBlock => continue,
            else => {
                failures += 1;
                if (failures == 1 or failures % 100 == 0) {
                    std.log.warn("accept failed ({s}, {d} in a row); still serving, retrying", .{ @errorName(err), failures });
                }
                // Out of descriptors/memory tends to last a moment: back off
                // (10 ms doubling to 1 s) instead of spinning on it, while the
                // connection deadlines free descriptors.
                const backoff_ms: i64 = @min(1000, @as(i64, 10) << @intCast(@min(failures - 1, 7)));
                std.Io.sleep(wctx.io, .fromMilliseconds(backoff_ms), .real) catch break;
                continue;
            },
        };
        if (failures > 0) {
            std.log.info("accept recovered after {d} failed attempts", .{failures});
            failures = 0;
        }

        group.concurrent(wctx.io, handleConnection, .{ConnCtx{
            .stream = stream,
            .io = wctx.io,
            .gpa = wctx.gpa,
            .router = wctx.router,
            .static_config = wctx.static_config,
            .views_index = wctx.views_index,
            .config = wctx.config,
            .error_handler = wctx.error_handler,
            ._db = wctx._db,
            .decorations = wctx.decorations,
            .ws_route_hubs = wctx.ws_route_hubs,
            .sse_hub = wctx.sse_hub,
            .global_middlewares = wctx.global_middlewares,
            .path_middlewares = wctx.path_middlewares,
            .watchdog = wctx.watchdog,
        }}) catch |err| {
            std.log.err("worker concurrent error: {s}", .{@errorName(err)});
            stream.close(wctx.io);
        };
    }

    group.await(wctx.io) catch {}; // canceled at shutdown: nothing left to report
}

fn isRequestIdChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.';
}

/// Echoed into logs and a response header, so only a short token of safe
/// characters is accepted from the client.
fn isSaneRequestId(v: []const u8) bool {
    if (v.len == 0 or v.len > 64) return false;
    for (v) |ch| if (!isRequestIdChar(ch)) return false;
    return true;
}

test "isSaneRequestId" {
    try std.testing.expect(isSaneRequestId("proxy-abc_123.4"));
    try std.testing.expect(!isSaneRequestId(""));
    try std.testing.expect(!isSaneRequestId("bad id <script>"));
    try std.testing.expect(!isSaneRequestId("a\r\nSet-Cookie: x"));
    var long: [65]u8 = undefined;
    @memset(&long, 'x');
    try std.testing.expect(!isSaneRequestId(&long));
}

/// Incoming X-Request-Id when it looks sane (e.g. set by a reverse proxy, so
/// its log lines and ours share one id), otherwise 16 random hex chars.
fn makeRequestId(io: Io, arena: std.mem.Allocator, headers: std.StringHashMapUnmanaged([]const u8)) []const u8 {
    var it = headers.iterator();
    while (it.next()) |e| {
        if (!std.ascii.eqlIgnoreCase(e.key_ptr.*, "X-Request-Id")) continue;
        const v = e.value_ptr.*;
        if (isSaneRequestId(v)) return v;
        break;
    }
    var rnd: [8]u8 = undefined;
    std.Io.random(io, &rnd);
    const hex = std.fmt.bytesToHex(rnd, .lower);
    return arena.dupe(u8, &hex) catch "-";
}

/// A failed write to the client is almost always the client going away
/// (closed tab, navigation, timeout) — debug level, not an error.
fn logRespondError(err: anyerror, rid: []const u8, method: []const u8, path: []const u8) void {
    std.log.debug("rid={s} {s} {s}: response not delivered ({s}); client likely disconnected", .{ rid, method, path, @errorName(err) });
}

/// Turns an error from the chain into a Response: the app's onError when
/// set, otherwise statusForError() + detail (JSON for fetch callers).
fn respondToError(error_handler: ?ErrorHandler, c: *Ctx, err: anyerror) Response {
    const method = @tagName(c.request.head.method);
    if (error_handler) |eh| {
        return eh(c, err) catch |eh_err| {
            std.log.err("rid={s} {s} {s}: onError failed with {s} while handling {s}", .{ c.requestId(), method, c.getPath(), @errorName(eh_err), @errorName(err) });
            return Response{ .status = .internal_server_error, .body = "Internal Server Error", .content_type = "text/plain" };
        };
    }
    const status = ctx_mod.statusForError(err);
    if (@intFromEnum(status) >= 500) {
        std.log.err("rid={s} {s} {s}: unhandled error {s}", .{ c.requestId(), method, c.getPath(), @errorName(err) });
    }
    const message = c.errorDetail() orelse (status.phrase() orelse "Error");
    if (c.wantsJson()) {
        return c.json(.{ .@"error" = @errorName(err), .message = message }, .{ .status = status }) catch
            Response{ .status = status, .body = message, .content_type = "text/plain" };
    }
    return c.text(message, .{ .status = status }) catch Response{ .status = status, .body = message, .content_type = "text/plain" };
}

/// Reads exactly `len` body bytes, re-arming the body deadline after every
/// read that makes progress: it bounds silence, not total upload time.
fn readBody(r: *Io.Reader, arena: std.mem.Allocator, len: u64, watch: *Watchdog.Entry, timeout_ms: u32) ![]u8 {
    const buf = try arena.alloc(u8, @intCast(len));
    var got: usize = 0;
    while (got < buf.len) {
        watch.arm(timeout_ms);
        const avail = try r.peekGreedy(1);
        const n = @min(avail.len, buf.len - got);
        @memcpy(buf[got..][0..n], avail[0..n]);
        r.toss(n);
        got += n;
    }
    watch.disarm();
    return buf;
}

fn handleConnection(ctx: ConnCtx) error{Canceled}!void {
    defer ctx.stream.close(ctx.io);
    // Registered after the close defer, so it is unregistered before the
    // socket is closed (see watchdog.zig on fd reuse).
    var watch: Watchdog.Entry = .{ .fd = ctx.stream.socket.handle };
    ctx.watchdog.add(&watch);
    defer ctx.watchdog.remove(&watch);

    var req_arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer req_arena.deinit();

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;

    var stream_reader = Io.net.Stream.Reader.init(ctx.stream, ctx.io, &read_buf);
    var stream_writer = Io.net.Stream.Writer.init(ctx.stream, ctx.io, &write_buf);

    var http = std.http.Server.init(
        &stream_reader.interface,
        &stream_writer.interface,
    );

    while (true) {
        _ = req_arena.reset(.{ .retain_with_limit = 8192 });
        const arena = req_arena.allocator();

        // Idle until the next request starts (keep-alive, or the first one),
        // then a separate, shorter budget for the rest of the head. No
        // deadline while the handler runs (SSE/WebSocket streams live there).
        watch.arm(ctx.config.keepalive_timeout_ms);
        stream_reader.interface.fill(1) catch break;
        watch.arm(ctx.config.header_timeout_ms);
        var request = http.receiveHead() catch break;
        watch.disarm();

        const target = request.head.target;
        const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;

        var headers_map: std.StringHashMapUnmanaged([]const u8) = .{};
        {
            var hdr_iter = request.iterateHeaders();
            while (hdr_iter.next()) |h| {
                headers_map.put(arena, h.name, h.value) catch |err| {
                    std.log.err("{s} {s}: dropped header {s} ({s})", .{ @tagName(request.head.method), path, h.name, @errorName(err) });
                };
            }
        }
        const request_id = makeRequestId(ctx.io, arena, headers_map);
        const method_name = @tagName(request.head.method);

        var body_error: ?anyerror = null;
        const body: ?[]const u8 = blk: {
            const cl = request.head.content_length orelse break :blk null;
            if (cl == 0) break :blk null;
            const target_copy = arena.dupe(u8, target) catch |err| {
                body_error = err;
                break :blk null;
            };
            var body_io_buf: [4096]u8 = undefined;
            const body_reader = request.readerExpectNone(&body_io_buf);
            request.head.target = target_copy;
            break :blk readBody(body_reader, arena, cl, &watch, ctx.config.body_timeout_ms) catch |err| {
                body_error = err;
                break :blk null;
            };
        };
        // A body that couldn't be read (client stalled/disconnected mid-upload,
        // OOM) used to reach the handler as "no body" and surface as a
        // misleading error.BodyEmpty. Answer 400 here instead, log the real
        // cause, and drop the connection: the stream position is unknown.
        if (body_error) |err| {
            std.log.warn("rid={s} {s} {s}: could not read request body ({d} bytes): {s}", .{ request_id, method_name, path, request.head.content_length orelse 0, @errorName(err) });
            request.respond("Could not read request body", .{
                .status = .bad_request,
                .extra_headers = &.{ .{ .name = "content-type", .value = "text/plain" }, .{ .name = "X-Request-Id", .value = request_id } },
                .keep_alive = false,
            }) catch |werr| logRespondError(werr, request_id, method_name, path);
            break;
        }

        {
            const static_hit = static_mod.serve(ctx.io, arena, ctx.static_config, path) catch |err| blk: {
                std.log.err("rid={s} {s} {s}: static file error {s}", .{ request_id, method_name, path, @errorName(err) });
                break :blk null;
            };
            if (static_hit) |static_response| {
                var extra_hdrs_buf: [2]std.http.Header = undefined;
                extra_hdrs_buf[0] = .{ .name = "content-type", .value = static_response.content_type };
                request.respond(static_response.body orelse "", .{
                    .status = static_response.status,
                    .extra_headers = extra_hdrs_buf[0..1],
                }) catch |err| {
                    logRespondError(err, request_id, method_name, path);
                    break;
                };
                if (!request.head.keep_alive) break;
                continue;
            }
        }

        const views_cfg: ?ViewsConfig = if (ctx.config.views_dir) |vd| ViewsConfig{
            .views_dir = vd,
            .layout = ctx.config.layout,
            .io = ctx.io,
            .arena = arena,
            .mode = .runtime,
            .index = ctx.views_index,
        } else null;

        // Only fails on OOM; that used to read as "no route" and answer 404.
        const match = ctx.router.match(request.head.method, path, arena) catch |err| {
            std.log.err("rid={s} {s} {s}: route lookup failed: {s}", .{ request_id, method_name, path, @errorName(err) });
            request.respond("Internal Server Error", .{
                .status = .internal_server_error,
                .extra_headers = &.{ .{ .name = "content-type", .value = "text/plain" }, .{ .name = "X-Request-Id", .value = request_id } },
                .keep_alive = false,
            }) catch |werr| logRespondError(werr, request_id, method_name, path);
            break;
        };
        const response = if (match) |m| blk: {
            var matched_hub: ?*Hub = null;
            for (ctx.ws_route_hubs) |rh| {
                if (rh.handler == m.handler) {
                    matched_hub = rh.hub;
                    break;
                }
            }
            var ctx_req = Ctx{
                .request = request,
                .arena = arena,
                .params = m.params,
                .body = body,
                ._db = ctx._db,
                ._views = views_cfg,
                ._io = ctx.io,
                ._stream = ctx.stream,
                ._headers = headers_map,
                ._decorations = ctx.decorations,
                ._ws_hub = matched_hub,
                ._sse_hub = ctx.sse_hub,
                ._request_id = request_id,
                ._watch = &watch,
                ._route = m.meta,
            };

            var mw_buf: [64]MiddlewareFn = undefined;
            const mw_count = collectMiddlewares(ctx.global_middlewares, ctx.path_middlewares, path, m.middlewares, &mw_buf);

            break :blk runChain(&ctx_req, mw_buf[0..mw_count], m.handler) catch |err|
                respondToError(ctx.error_handler, &ctx_req, err);
        } else blk: {
            var ctx_req = Ctx{
                .request = request,
                .arena = arena,
                .params = .{},
                .body = body,
                ._db = ctx._db,
                ._views = views_cfg,
                ._io = ctx.io,
                ._stream = ctx.stream,
                ._headers = headers_map,
                ._decorations = ctx.decorations,
                ._ws_hub = null,
                ._sse_hub = ctx.sse_hub,
                ._request_id = request_id,
                ._watch = &watch,
            };
            var mw_buf_404: [64]MiddlewareFn = undefined;
            const mw_count_404 = collectMiddlewares(ctx.global_middlewares, ctx.path_middlewares, path, &.{}, &mw_buf_404);
            // No route: error.NotFound through the same path as any handler
            // error, so an app's onError renders its own 404 (it used to be a
            // fixed text response that bypassed onError).
            const notFoundHandler: Handler = struct {
                fn h(_: *Ctx) anyerror!Response {
                    return error.NotFound;
                }
            }.h;
            break :blk runChain(&ctx_req, mw_buf_404[0..mw_count_404], notFoundHandler) catch |err|
                respondToError(ctx.error_handler, &ctx_req, err);
        };

        var extra_headers_buf: [32]std.http.Header = undefined;
        var header_count: usize = 0;
        extra_headers_buf[header_count] = .{ .name = "content-type", .value = response.content_type };
        header_count += 1;
        extra_headers_buf[header_count] = .{ .name = "X-Request-Id", .value = request_id };
        header_count += 1;
        for (response.headers) |h| {
            if (header_count < 32) {
                extra_headers_buf[header_count] = .{ .name = h[0], .value = h[1] };
                header_count += 1;
            }
        }
        for (response.cookies) |c| {
            if (header_count < 32) {
                extra_headers_buf[header_count] = .{ .name = "Set-Cookie", .value = c[1] };
                header_count += 1;
            }
        }
        if (response.raw) {
            if (!request.head.keep_alive) break;
            continue;
        }

        const final_body = response.body orelse "";

        // std.http.Server.Request.discardBody() asserts that a body-bearing
        // method always carries Content-Length or Transfer-Encoding when the
        // connection is being kept alive — but that invariant isn't enforced
        // at head-parsing time, so a malformed request (e.g. a bare POST with
        // neither header) reaches discardBody() in a state that violates it,
        // crashing the whole process with "reached unreachable code". Skip
        // keep-alive for exactly that case: discardBody() only takes the
        // asserting branch when keep_alive is true on both ends, so passing
        // false here for a malformed request avoids the crash without paying
        // the keep-alive cost on every other (well-formed) request.
        const malformed_body_request = request.head.method.requestHasBody() and
            request.head.transfer_encoding == .none and
            request.head.content_length == null;

        request.respond(final_body, .{
            .status = response.status,
            .extra_headers = extra_headers_buf[0..header_count],
            .keep_alive = !malformed_body_request,
        }) catch |err| {
            logRespondError(err, request_id, method_name, path);
            break;
        };

        if (!request.head.keep_alive or malformed_body_request) break;
    }
}

pub const ListenOptions = struct {
    port: ?u16 = null,
    host: ?[]const u8 = null,
};

fn findFieldName(comptime T: type, comptime ParamType: type) []const u8 {
    const T_info = @typeInfo(T).@"struct";
    inline for (T_info.field_names, T_info.field_types) |fname, ftype| {
        if (ftype == ParamType) {
            return fname;
        }
    }
    @compileError("field not found");
}

fn buildWrapper(comptime handler: anytype, comptime T: type) Handler {
    const fn_info = @typeInfo(@TypeOf(handler)).@"fn";
    const extra = fn_info.param_types[1..];
    const extra_len = extra.len;

    if (extra_len == 0) return @as(Handler, handler);

    comptime {
        const T_info = @typeInfo(T).@"struct";
        for (extra) |p| {
            const pt = p orelse @compileError("generic param not supported");
            var found = false;
            for (T_info.field_types) |ft| {
                if (ft == pt) found = true;
            }
            if (!found) {
                @compileError(std.fmt.comptimePrint(
                    "handler requires type `{s}` which was not provided to spider.app(). " ++
                        "Add a field of this type to the app() argument.",
                    .{@typeName(pt)},
                ));
            }
        }
    }

    const W = struct {
        pub fn call(ctx: *Ctx) anyerror!Response {
            const decos: *const T = @as(*const T, @ptrCast(@alignCast(ctx._decorations.?)));

            if (extra_len == 1) {
                const f0 = comptime findFieldName(T, extra[0].?);
                return handler(ctx, @field(decos, f0));
            }
            if (extra_len == 2) {
                const f0 = comptime findFieldName(T, extra[0].?);
                const f1 = comptime findFieldName(T, extra[1].?);
                return handler(ctx, @field(decos, f0), @field(decos, f1));
            }
            if (extra_len == 3) {
                const f0 = comptime findFieldName(T, extra[0].?);
                const f1 = comptime findFieldName(T, extra[1].?);
                const f2 = comptime findFieldName(T, extra[2].?);
                return handler(ctx, @field(decos, f0), @field(decos, f1), @field(decos, f2));
            }
            if (extra_len == 4) {
                const f0 = comptime findFieldName(T, extra[0].?);
                const f1 = comptime findFieldName(T, extra[1].?);
                const f2 = comptime findFieldName(T, extra[2].?);
                const f3 = comptime findFieldName(T, extra[3].?);
                return handler(ctx, @field(decos, f0), @field(decos, f1), @field(decos, f2), @field(decos, f3));
            }
            @compileError("max 4 extra params supported");
        }
    };
    return W.call;
}

fn buildWsWrapper(comptime handler: fn (*Ws) anyerror!void) Handler {
    const W = struct {
        pub fn call(ctx: *Ctx) anyerror!Response {
            const hub = ctx._ws_hub orelse return ctx.text("", .{});
            var ws_server = websocket.Server.init(ctx._stream, ctx._io, ctx.arena);
            if (!try ws_server.handshake(ctx.arena, &ctx._headers)) {
                return ctx.text("", .{});
            }

            var rand_buf: [8]u8 = undefined;
            std.Io.random(ctx._io, &rand_buf);
            const conn_id = std.mem.readInt(u64, &rand_buf, .little);
            try hub.add(.{ .id = conn_id, .stream = ctx._stream, .watch = ctx._watch });
            defer hub.remove(conn_id);

            var ws = Ws{
                ._server = ws_server,
                ._hub = hub,
                ._conn_id = conn_id,
                .params = ctx.params,
                .arena = ctx.arena,
                .io = ctx._io,
            };

            try handler(&ws);
            return Response{ .raw = true, .status = .switching_protocols };
        }
    };
    return W.call;
}

/// Passed to a feature's `boot()` (see Server.mountFeatures).
pub const Boot = struct {
    /// Thread-safe, lives for the whole process.
    allocator: std.mem.Allocator,
    /// The server's Io.
    io: Io,
};
pub const BootFn = *const fn (Boot) anyerror!void;

/// A periodic task a feature declares: `pub const jobs = .{spider.every(60_000, retryLoop)};`
/// Runs on its own thread every `every_ms` with the SSE hub (like sseInterval).
pub const Job = struct {
    every_ms: u64,
    run: *const fn (*Hub) void,
};

pub fn every(every_ms: u64, run: *const fn (*Hub) void) Job {
    return .{ .every_ms = every_ms, .run = run };
}

const IntervalEntry = struct {
    hub: *Hub,
    ms: u64,
    callback: *const fn (*Hub) void,
    io: std.Io,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    thread: ?std.Thread = null,
};

fn intervalLoop(entry: *IntervalEntry) void {
    while (entry.running.load(.acquire)) {
        std.Io.sleep(
            entry.io,
            std.Io.Duration.fromMilliseconds(@as(i64, @intCast(entry.ms))),
            .real,
        ) catch {}; // only fails when canceled at shutdown; the loop re-checks `running`
        if (entry.running.load(.acquire)) {
            entry.callback(entry.hub);
        }
    }
}

pub fn Server(comptime T: type) type {
    return struct {
        const Self = @This();

        spider_arena: std.heap.ArenaAllocator,
        spider_gpa: std.heap.DebugAllocator(.{}),
        allocator: std.mem.Allocator,
        gpa: std.mem.Allocator,
        router: Router,
        decorations: T,
        global_middlewares: [16]MiddlewareFn = undefined,
        global_middleware_count: usize = 0,
        path_middlewares: [32]PathMiddlewareEntry = undefined,
        path_middleware_count: usize = 0,
        error_handler: ?ErrorHandler = null,
        _db: ?Database = null,
        static_config: StaticConfig = .{ .dir = "./public", .prefix = "/" },
        config: Config = default_config,
        views_index: ?views_mod.ViewsIndex = null,
        ws_route_hubs: std.ArrayListUnmanaged(WsRouteHub) = .empty,
        sse_hub: ?Hub = null,
        sse_threaded: ?std.Io.Threaded = null,
        /// Requested via sseHeartbeat()/sseSweep(); started by listen() once
        /// the hub runs on the server's Io (see bindHubs).
        sse_heartbeat_ms: ?u64 = null,
        sse_sweep_ms: ?u64 = null,
        interval_threads: std.ArrayListUnmanaged(IntervalEntry) = .empty,
        /// Features' boot() hooks, run by listen() before the first accept.
        boot_hooks: std.ArrayListUnmanaged(BootFn) = .empty,

        pub fn init() Self {
            env.autoLoad(std.heap.page_allocator);
            env.checkGitignore();

            var self: Self = .{
                .spider_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .spider_gpa = .init,
                .allocator = undefined,
                .gpa = undefined,
                .router = Router.init(std.heap.page_allocator) catch unreachable,
                .decorations = undefined,
                .global_middleware_count = 0,
                .path_middleware_count = 0,
            };
            self.allocator = std.heap.page_allocator;
            self.gpa = if (builtin.mode == .Debug)
                self.spider_gpa.allocator()
            else
                std.heap.smp_allocator;
            return self;
        }

        pub fn deinit(self: *Self) void {
            for (self.interval_threads.items) |*e| {
                e.running.store(false, .release);
            }
            for (self.interval_threads.items) |*e| {
                if (e.thread) |t| t.join();
            }
            if (self.views_index) |*idx| idx.deinit();
            self.router.deinit();
            for (self.ws_route_hubs.items) |*rh| {
                rh.threaded.deinit();
                rh.hub.deinit();
                std.heap.smp_allocator.destroy(rh.hub);
            }
            self.ws_route_hubs.deinit(std.heap.smp_allocator);
            if (self.sse_hub) |*h| h.deinit();
            if (self.sse_threaded) |*t| t.deinit();
            self.interval_threads.deinit(std.heap.smp_allocator);
            if (self._db) |db_ptr| db_ptr.deinit();
            _ = self.spider_gpa.deinit();
            self.spider_arena.deinit();
        }

        pub fn use(self: *Self, m: MiddlewareFn) *Self {
            if (self.global_middleware_count < 16) {
                self.global_middlewares[self.global_middleware_count] = m;
                self.global_middleware_count += 1;
            }
            return self;
        }

        pub fn useAt(self: *Self, path: []const u8, m: MiddlewareFn) *Self {
            if (self.path_middleware_count >= self.path_middlewares.len) {
                std.debug.panic(
                    "Server.useAt: path middleware capacity exceeded (max {d}) registering \"{s}\"",
                    .{ self.path_middlewares.len, path },
                );
            }
            self.path_middlewares[self.path_middleware_count] = .{ .path = path, .middleware = m };
            self.path_middleware_count += 1;
            return self;
        }

        pub fn onError(self: *Self, handler: ErrorHandler) *Self {
            self.error_handler = handler;
            return self;
        }

        pub fn db(self: *Self, database: Database) *Self {
            self._db = database;
            return self;
        }

        pub fn staticDir(self: *Self, dir: []const u8) *Self {
            self.static_config = .{ .dir = dir, .prefix = "/" };
            return self;
        }

        pub fn staticAt(self: *Self, dir: []const u8, prefix: []const u8) *Self {
            self.static_config = .{ .dir = dir, .prefix = prefix };
            return self;
        }

        pub fn get(self: *Self, path: []const u8, handler: anytype, comptime config: anytype) *Self {
            const H = if (@TypeOf(handler) == Handler)
                handler
            else if (comptime usesExtractors(handler))
                buildAutoWrapper(handler)
            else
                buildWrapper(handler, T);
            self.router.addRoute(.GET, path, .{
                .handler = H,
                .middlewares = comptime route_config.middlewares(config),
                .meta = comptime route_config.metaOf(config),
            }) catch unreachable;
            return self;
        }

        pub fn post(self: *Self, path: []const u8, handler: anytype, comptime config: anytype) *Self {
            const H = if (@TypeOf(handler) == Handler)
                handler
            else if (comptime usesExtractors(handler))
                buildAutoWrapper(handler)
            else
                buildWrapper(handler, T);
            self.router.addRoute(.POST, path, .{
                .handler = H,
                .middlewares = comptime route_config.middlewares(config),
                .meta = comptime route_config.metaOf(config),
            }) catch unreachable;
            return self;
        }

        pub fn put(self: *Self, path: []const u8, handler: anytype, comptime config: anytype) *Self {
            const H = if (@TypeOf(handler) == Handler)
                handler
            else if (comptime usesExtractors(handler))
                buildAutoWrapper(handler)
            else
                buildWrapper(handler, T);
            self.router.addRoute(.PUT, path, .{
                .handler = H,
                .middlewares = comptime route_config.middlewares(config),
                .meta = comptime route_config.metaOf(config),
            }) catch unreachable;
            return self;
        }

        pub fn delete(self: *Self, path: []const u8, handler: anytype, comptime config: anytype) *Self {
            const H = if (@TypeOf(handler) == Handler)
                handler
            else if (comptime usesExtractors(handler))
                buildAutoWrapper(handler)
            else
                buildWrapper(handler, T);
            self.router.addRoute(.DELETE, path, .{
                .handler = H,
                .middlewares = comptime route_config.middlewares(config),
                .meta = comptime route_config.metaOf(config),
            }) catch unreachable;
            return self;
        }

        pub fn patch(self: *Self, path: []const u8, handler: anytype, comptime config: anytype) *Self {
            const H = if (@TypeOf(handler) == Handler)
                handler
            else if (comptime usesExtractors(handler))
                buildAutoWrapper(handler)
            else
                buildWrapper(handler, T);
            self.router.addRoute(.PATCH, path, .{
                .handler = H,
                .middlewares = comptime route_config.middlewares(config),
                .meta = comptime route_config.metaOf(config),
            }) catch unreachable;
            return self;
        }

        pub fn head(self: *Self, path: []const u8, handler: anytype, comptime config: anytype) *Self {
            const H = if (@TypeOf(handler) == Handler)
                handler
            else if (comptime usesExtractors(handler))
                buildAutoWrapper(handler)
            else
                buildWrapper(handler, T);
            self.router.addRoute(.HEAD, path, .{
                .handler = H,
                .middlewares = comptime route_config.middlewares(config),
                .meta = comptime route_config.metaOf(config),
            }) catch unreachable;
            return self;
        }

        pub fn ws(self: *Self, path: []const u8, comptime handler: fn (*Ws) anyerror!void) *Self {
            var threaded = std.Io.Threaded.init_single_threaded;
            const hub_ptr = std.heap.smp_allocator.create(Hub) catch unreachable;
            hub_ptr.* = Hub.init(std.heap.smp_allocator, threaded.io());
            const H = buildWsWrapper(handler);
            self.router.add(.GET, path, H) catch unreachable;
            self.ws_route_hubs.append(std.heap.smp_allocator, .{
                .handler = H,
                .hub = hub_ptr,
                .threaded = threaded,
            }) catch unreachable;
            return self;
        }

        pub fn wsInterval(self: *Self, path: []const u8, ms: u64, comptime callback: fn (*Hub) void) *Self {
            var threaded = std.Io.Threaded.init_single_threaded;
            const hub_ptr = std.heap.smp_allocator.create(Hub) catch unreachable;
            hub_ptr.* = Hub.init(std.heap.smp_allocator, threaded.io());
            const H = buildWsWrapper(struct {
                fn handle(w: *Ws) anyerror!void {
                    while (try w.next()) |_| {}
                }
            }.handle);
            self.router.add(.GET, path, H) catch unreachable;
            self.ws_route_hubs.append(std.heap.smp_allocator, .{
                .handler = H,
                .hub = hub_ptr,
                .threaded = threaded,
            }) catch unreachable;
            self.interval_threads.append(std.heap.smp_allocator, .{
                .hub = hub_ptr,
                .ms = ms,
                .callback = callback,
                .io = undefined,
            }) catch |err| std.log.err("interval not scheduled: {s}", .{@errorName(err)});
            return self;
        }

        // Lazily creates the server's single shared SSE hub. Idempotent —
        // safe to call from .sse(), .sseInterval(), and mount() (when a
        // mounted Group has SSE routes of its own).
        //
        // The dedicated Io.Threaded only serves calls made before listen()
        // (e.g. an emit during setup); listen() switches the hub to the
        // server's own Io (bindHubs) before the first connection.
        fn ensureSseHub(self: *Self) void {
            if (self.sse_hub == null) {
                self.sse_threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
                self.sse_hub = Hub.init(std.heap.smp_allocator, self.sse_threaded.?.io());
            }
        }

        pub fn sseInterval(self: *Self, ms: u64, comptime callback: fn (*Hub) void) *Self {
            self.ensureSseHub();
            self.interval_threads.append(std.heap.smp_allocator, .{
                .hub = if (self.sse_hub) |*h| h else unreachable,
                .ms = ms,
                .callback = callback,
                .io = undefined,
            }) catch |err| std.log.err("interval not scheduled: {s}", .{@errorName(err)});
            return self;
        }

        /// Starts the shared SSE hub's heartbeat (": heartbeat\n\n" on every
        /// interval, keeping connections warm against idle-timeout
        /// proxies/LBs). `interval_ms` null uses Hub.default_heartbeat_ms
        /// (30s). Best-effort — spawn failure is rare (thread/OOM limits)
        /// and not worth failing server startup over, matching sseInterval's
        /// own `catch {}` above.
        pub fn sseHeartbeat(self: *Self, interval_ms: ?u64) *Self {
            self.ensureSseHub();
            self.sse_heartbeat_ms = interval_ms orelse Hub.default_heartbeat_ms;
            return self;
        }

        /// Starts the shared SSE hub's proactive dead-connection sweep —
        /// independent of sseHeartbeat, so a channel that's both quiet and
        /// never emitted to doesn't accumulate zombie connections
        /// indefinitely. `interval_ms` null uses Hub.default_sweep_ms (60s).
        pub fn sseSweep(self: *Self, interval_ms: ?u64) *Self {
            self.ensureSseHub();
            self.sse_sweep_ms = interval_ms orelse Hub.default_sweep_ms;
            return self;
        }

        /// Puts every hub on the server's Io before the first connection.
        /// Hub writes used to go through their own Io.Threaded: on the zio
        /// backend the sockets are non-blocking, so a client with a full
        /// buffer made the write fail with EAGAIN — a panic in Debug, a
        /// silently dropped client in release builds. Heartbeat/sweep start
        /// only now, so no hub mutex is ever shared by two Io implementations.
        fn bindHubs(self: *Self, io: Io) void {
            const write_ms = self.config.stream_write_timeout_ms;
            if (self.sse_hub) |*hub| {
                hub.io = io;
                hub.write_timeout_ms = write_ms;
                if (self.sse_heartbeat_ms) |ms| hub.startHeartbeat(ms) catch |err|
                    std.log.err("SSE heartbeat not started: {s}", .{@errorName(err)});
                if (self.sse_sweep_ms) |ms| hub.startSweep(ms) catch |err|
                    std.log.err("SSE sweep not started: {s}", .{@errorName(err)});
            }
            for (self.ws_route_hubs.items) |rh| {
                rh.hub.io = io;
                rh.hub.write_timeout_ms = write_ms;
            }
        }

        pub fn sse(self: *Self, path: []const u8, comptime handler: fn (*Sse) anyerror!void) *Self {
            self.ensureSseHub();
            const H = sse_mod.buildHandler(handler);
            self.router.add(.GET, path, H) catch unreachable;
            return self;
        }

        /// sse() with a route config, like get(): `.roles`, `.org_roles`,
        /// `.public`, `.quiet_log`, `.allow_http`.
        pub fn sseWith(self: *Self, path: []const u8, comptime handler: fn (*Sse) anyerror!void, comptime config: anytype) *Self {
            self.ensureSseHub();
            self.router.addRoute(.GET, path, .{
                .handler = sse_mod.buildHandler(handler),
                .middlewares = comptime route_config.middlewares(config),
                .meta = comptime route_config.metaOf(config),
            }) catch unreachable;
            return self;
        }

        pub fn health(self: *Self, path: []const u8, comptime handler: anytype) *Self {
            return self.get(path, handler, .{});
        }

        pub fn addRoute(
            self: *Self,
            method: std.http.Method,
            path: []const u8,
            middlewares: []const MiddlewareFn,
            handler: Handler,
        ) void {
            self.router.addRoute(method, path, .{ .handler = handler, .middlewares = middlewares }) catch |err|
                std.log.err("route {s} {s} not registered: {s}", .{ @tagName(method), path, @errorName(err) });
        }

        pub fn group(
            self: *Self,
            prefix: []const u8,
            middlewares: []const MiddlewareFn,
            register: *const fn (*Self, []const u8, []const MiddlewareFn) void,
        ) *Self {
            register(self, prefix, middlewares);
            return self;
        }

        /// Registers every feature of an app's `features` module: for each
        /// `pub const <name>` that is a namespace, see mountFeature().
        /// Features are visited in declaration order; route matching doesn't
        /// depend on registration order.
        pub fn mountFeatures(self: *Self, comptime features: type) *Self {
            inline for (@typeInfo(features).@"struct".decl_names) |name| {
                const F = @field(features, name);
                if (@TypeOf(F) == type and @typeInfo(F) == .@"struct") _ = self.mountFeature(F);
            }
            return self;
        }

        /// Registers one feature namespace (usually its mod.zig):
        ///   - `routes`: every `pub fn` with no parameters returning
        ///     `spider.Group` is mounted (e.g. build(), buildWebhook()).
        ///   - `jobs`: a tuple of `spider.every(ms, fn (*spider.Hub) void)`.
        ///   - `boot`: `pub fn boot(b: spider.Boot) !void`, run by listen()
        ///     before the first connection (not when only listing routes).
        /// Anything else in the namespace is ignored. `mount()` stays for
        /// groups that live elsewhere.
        pub fn mountFeature(self: *Self, comptime F: type) *Self {
            if (@hasDecl(F, "routes") and @TypeOf(F.routes) == type and @typeInfo(F.routes) == .@"struct") {
                inline for (@typeInfo(F.routes).@"struct".decl_names) |fname| {
                    const f = @field(F.routes, fname);
                    const FT = @TypeOf(f);
                    if (comptime @typeInfo(FT) == .@"fn") {
                        const info = @typeInfo(FT).@"fn";
                        if (comptime info.param_types.len == 0 and info.return_type == Group) _ = self.mount(f());
                    }
                }
            }
            if (@hasDecl(F, "jobs")) {
                inline for (F.jobs) |job| {
                    const j: Job = job;
                    self.ensureSseHub();
                    self.interval_threads.append(std.heap.smp_allocator, .{
                        .hub = if (self.sse_hub) |*h| h else unreachable,
                        .ms = j.every_ms,
                        .callback = j.run,
                        .io = undefined,
                    }) catch |err| std.log.err("job not scheduled: {s}", .{@errorName(err)});
                }
            }
            if (@hasDecl(F, "boot")) {
                self.boot_hooks.append(std.heap.smp_allocator, F.boot) catch |err|
                    std.log.err("boot hook not registered: {s}", .{@errorName(err)});
            }
            return self;
        }

        fn runBootHooks(self: *Self, io: Io) !void {
            for (self.boot_hooks.items) |hook| {
                hook(.{ .allocator = std.heap.smp_allocator, .io = io }) catch |err| {
                    std.log.err("feature boot() failed: {s}", .{@errorName(err)});
                    return err;
                };
            }
        }

        pub fn mount(self: *Self, child: Group) *Self {
            const MountCtx = struct { s: *Self, use: []const MiddlewareFn };
            const mctx: MountCtx = .{ .s = self, .use = child.use_middlewares[0..child.use_count] };
            child.router.forEach(std.heap.page_allocator, mctx, struct {
                fn cb(m: MountCtx, method: std.http.Method, path: []const u8, route: Route) void {
                    var r = route;
                    // Group.use(): after the route's own (RBAC) middlewares.
                    if (m.use.len > 0) {
                        const all = std.heap.page_allocator.alloc(MiddlewareFn, r.middlewares.len + m.use.len) catch @panic("OOM");
                        @memcpy(all[0..r.middlewares.len], r.middlewares);
                        @memcpy(all[r.middlewares.len..], m.use);
                        r.middlewares = all;
                    }
                    m.s.router.addRoute(method, path, r) catch |err|
                        std.log.err("mounted route {s} {s} not registered: {s}", .{ @tagName(method), path, @errorName(err) });
                }
            }.cb);

            const remaining = self.path_middlewares.len - self.path_middleware_count;
            if (child.path_middleware_count > remaining) {
                std.debug.panic(
                    "Server.mount: path middleware capacity exceeded (max {d} total across all .useAt() and .mount() calls) while mounting group prefix \"{s}\" ({d} entries, {d} slots remaining)",
                    .{ self.path_middlewares.len, child.prefix, child.path_middleware_count, remaining },
                );
            }
            for (child.path_middlewares[0..child.path_middleware_count]) |entry| {
                self.path_middlewares[self.path_middleware_count] = .{
                    .path = entry.path,
                    .middleware = entry.middleware,
                };
                self.path_middleware_count += 1;
            }

            // The SSE route itself was already wrapped into a plain Handler
            // inside Group.sse(), so forEach()'s generic copy above already
            // carried it over correctly — this only needs to make sure the
            // server's shared hub exists for it to actually work at runtime.
            if (child.has_sse) self.ensureSseHub();

            return self;
        }

        /// One watchdog thread per listening server, only when some
        /// connection deadline is enabled (see Config.*_timeout_ms).
        fn startWatchdog(self: *Self, watchdog: *Watchdog, io: Io) void {
            const timeouts = [_]u32{ self.config.keepalive_timeout_ms, self.config.header_timeout_ms, self.config.body_timeout_ms, self.config.stream_write_timeout_ms };
            if (std.mem.allEqual(u32, &timeouts, 0)) return;
            const t = std.Thread.spawn(.{}, Watchdog.run, .{ watchdog, io, watchdog_mod.tickFor(&timeouts) }) catch |err| {
                std.log.warn("connection deadlines disabled: watchdog thread not started ({s})", .{@errorName(err)});
                return;
            };
            t.detach();
        }

        /// The route table: method, path, access and flags, sorted by path.
        /// Printed by listen() instead of serving when SPIDER_ROUTES is set
        /// (what `spider routes` does).
        pub fn writeRoutes(self: *Self, w: *std.Io.Writer) !void {
            const list = try self.router.entries(std.heap.page_allocator);
            defer Router.freeEntries(std.heap.page_allocator, list);
            for (list) |e| {
                const m = e.route.meta;
                try w.print("{s: <7} {s: <48} ", .{ @tagName(e.method), e.path });
                try m.writeAccess(w);
                if (m.quiet_log) try w.writeAll("  quiet_log");
                if (m.allow_http) try w.writeAll("  allow_http");
                try w.writeAll("\n");
            }
            try w.print("{d} routes", .{list.len});
            if (self.router.duplicates > 0) try w.print(", {d} registered twice (see the warnings above)", .{self.router.duplicates});
            try w.writeAll("\n");

            // Background jobs (sseInterval / features' jobs), shortest first.
            const ms = try self.jobIntervals(std.heap.page_allocator);
            defer std.heap.page_allocator.free(ms);
            if (ms.len > 0) {
                try w.print("{d} background jobs, every:", .{ms.len});
                for (ms) |v| try w.print(" {d}ms", .{v});
                try w.writeAll("\n");
            }
        }

        fn jobIntervals(self: *Self, allocator: std.mem.Allocator) ![]u64 {
            const ms = try allocator.alloc(u64, self.interval_threads.items.len);
            for (self.interval_threads.items, 0..) |e, i| ms[i] = e.ms;
            std.mem.sort(u64, ms, {}, std.sort.asc(u64));
            return ms;
        }

        /// The route listing as one line of JSON (`SPIDER_ROUTES=json`, read
        /// by `spider routes --json/--check/--lock/--diff`):
        /// {"auth":bool,"routes":[{"method","path","access","public","roles",
        /// "org_roles","quiet_log","allow_http","policy"}],"jobs_ms":[..],"duplicates":n}
        pub fn writeRoutesJson(self: *Self, w: *std.Io.Writer) !void {
            const list = try self.router.entries(std.heap.page_allocator);
            defer Router.freeEntries(std.heap.page_allocator, list);
            const ms = try self.jobIntervals(std.heap.page_allocator);
            defer std.heap.page_allocator.free(ms);
            var js: std.json.Stringify = .{ .writer = w };
            try js.beginObject();
            try js.objectField("auth");
            try js.write(self.hasAuth());
            try js.objectField("routes");
            try js.beginArray();
            for (list) |e| {
                const m = e.route.meta;
                var buf: [512]u8 = undefined;
                var aw: std.Io.Writer = .fixed(&buf);
                m.writeAccess(&aw) catch {};
                try js.beginObject();
                try js.objectField("method");
                try js.write(@tagName(e.method));
                try js.objectField("path");
                try js.write(e.path);
                try js.objectField("access");
                try js.write(aw.buffered());
                try js.objectField("public");
                try js.write(m.public);
                try js.objectField("authenticated");
                try js.write(m.authenticated);
                try js.objectField("roles");
                try js.write(m.roles);
                try js.objectField("org_roles");
                try js.write(m.org_roles);
                try js.objectField("quiet_log");
                try js.write(m.quiet_log);
                try js.objectField("allow_http");
                try js.write(m.allow_http);
                try js.objectField("policy");
                try js.write(m.policy);
                try js.endObject();
            }
            try js.endArray();
            try js.objectField("jobs_ms");
            try js.write(ms);
            try js.objectField("duplicates");
            try js.write(self.router.duplicates);
            try js.endObject();
            try w.writeAll("\n");
        }

        /// A middleware installed with use()/useAt() authenticates requests
        /// (Spider's providers, or one marked with spider.markAuthMiddleware).
        pub fn hasAuth(self: *Self) bool {
            for (self.global_middlewares[0..self.global_middleware_count]) |m| {
                if (auth_marker.isMarked(m)) return true;
            }
            for (self.path_middlewares[0..self.path_middleware_count]) |e| {
                if (auth_marker.isMarked(e.middleware)) return true;
            }
            return false;
        }

        /// Every route must say who may call it (`.public`, `.authenticated`,
        /// `.roles`, `.org_roles` or `.policy`): listen() refuses to start otherwise, listing the
        /// ones that don't. Same as `require_route_access = true` in
        /// spider.config.zig. Off by default.
        pub fn requireRouteAccess(self: *Self) *Self {
            self.config.require_route_access = true;
            return self;
        }

        /// The boot check behind require_route_access: logs every route
        /// without declared access and fails with error.RouteAccessUndeclared.
        /// Does nothing when the option is off.
        pub fn checkRouteAccess(self: *Self) !void {
            if (!self.config.require_route_access) return;
            const list = try self.router.entries(std.heap.page_allocator);
            defer Router.freeEntries(std.heap.page_allocator, list);
            // warn under `zig test`: the test runner fails any test that logs at err.
            const log = if (@import("builtin").is_test) std.log.warn else std.log.err;
            var missing: usize = 0;
            for (list) |e| {
                if (e.route.meta.declaresAccess()) continue;
                // Development-only live reload: left to the app's auth like
                // before (it may exist in production when env stays .development).
                if (std.mem.eql(u8, e.path, livereload_path)) continue;
                missing += 1;
                log("route {s} {s} declares no access (require_route_access): add .public, .authenticated, .roles, .org_roles or .policy to its config, or a defaults() to its group", .{ @tagName(e.method), e.path });
            }
            if (missing > 0) {
                log("{d} route(s) without declared access; not starting", .{missing});
                return error.RouteAccessUndeclared;
            }
        }

        pub fn listen(self: *Self, options: ListenOptions) !void {
            if (env.get("SPIDER_ROUTES")) |mode| {
                var threaded = std.Io.Threaded.init_single_threaded;
                var buf: [4096]u8 = undefined;
                var out = std.Io.File.stdout().writer(threaded.io(), &buf);
                if (std.mem.eql(u8, mode, "json")) try self.writeRoutesJson(&out.interface) else try self.writeRoutes(&out.interface);
                try out.interface.flush();
                return;
            }
            try self.checkRouteAccess();
            if (comptime build_options.io_backend == .zio) {
                return self.listenZio(options);
            }
            return self.listenThreaded(options);
        }

        /// Default backend. One `Io.Threaded` pool shared by every worker
        /// thread; each of the `cpu_count` threads below runs its own
        /// `accept()` loop directly against the listener socket.
        fn listenThreaded(self: *Self, options: ListenOptions) !void {
            const port = options.port orelse self.config.port;
            const host = options.host orelse self.config.host;

            const gpa = std.heap.smp_allocator;

            var threaded: Io.Threaded = .init(gpa, .{});
            defer threaded.deinit();
            const io = threaded.io();

            const address = try Io.net.IpAddress.parse(host, port);
            var listener = try address.listen(io, .{ .reuse_address = true });
            defer listener.deinit(io);

            std.log.info("Server listening on http://{s}:{d}", .{ host, port });

            var watchdog: Watchdog = .{};
            self.startWatchdog(&watchdog, io);
            self.bindHubs(io);
            try self.runBootHooks(io);

            for (self.interval_threads.items) |*entry| {
                entry.io = io;
                entry.thread = std.Thread.spawn(.{}, intervalLoop, .{entry}) catch continue;
            }

            const cpu_count = std.Thread.getCpuCount() catch 2;

            const threads = try gpa.alloc(std.Thread, cpu_count);
            defer gpa.free(threads);

            const views_idx_ptr: ?*const views_mod.ViewsIndex = if (self.views_index) |*idx| idx else null;

            const worker_ctx = WorkerCtx{
                .io = io,
                .gpa = gpa,
                .listener = &listener,
                .router = &self.router,
                .static_config = self.static_config,
                .views_index = views_idx_ptr,
                .config = self.config,
                .error_handler = self.error_handler,
                ._db = if (self._db) |*d| @as(*const Database, d) else null,
                .decorations = if (@sizeOf(T) == 0) null else @as(*const anyopaque, @ptrCast(&self.decorations)),
                .ws_route_hubs = self.ws_route_hubs.items,
                .sse_hub = if (self.sse_hub) |*h| h else null,
                .global_middlewares = self.global_middlewares[0..self.global_middleware_count],
                .path_middlewares = self.path_middlewares[0..self.path_middleware_count],
                .watchdog = &watchdog,
            };

            for (threads) |*t| {
                t.* = std.Thread.spawn(.{}, workerLoop, .{worker_ctx}) catch |err| {
                    std.log.err("failed to spawn worker thread: {s}", .{@errorName(err)});
                    continue;
                };
            }

            for (threads) |t| t.join();
        }

        /// Experimental backend (`-Dio_backend=zio`). `zio.Runtime` manages
        /// its own N executors internally, so unlike `listenThreaded` this
        /// does not spawn cpu_count raw OS threads each doing their own
        /// accept() — a single `workerLoop` call is enough: its
        /// `group.concurrent()` call (unchanged, shared with the threaded
        /// backend) is what the runtime actually distributes across
        /// executors.
        fn listenZio(self: *Self, options: ListenOptions) !void {
            const zio = @import("zio");

            const port = options.port orelse self.config.port;
            const host = options.host orelse self.config.host;

            const gpa = std.heap.smp_allocator;

            // A "Coroutine stack overflow!" abort chased through this code
            // turned out to be a red herring: root cause was an app-level
            // template bug (a component including itself, unbounded
            // recursive parse+render — see git history on
            // BottomNavGatekeeper.html in orbitx), not anything about zio's
            // stack sizing or pooling. Left at zio's own defaults.
            var rt = try zio.Runtime.init(gpa, .{
                .executors = .auto,
            });
            defer rt.deinit();
            const io = rt.io();

            const address = try Io.net.IpAddress.parse(host, port);
            var listener = try address.listen(io, .{ .reuse_address = true });
            defer listener.deinit(io);

            std.log.info("Server listening on http://{s}:{d} (io_backend=zio)", .{ host, port });

            var watchdog: Watchdog = .{};
            self.startWatchdog(&watchdog, io);
            self.bindHubs(io);
            try self.runBootHooks(io);

            for (self.interval_threads.items) |*entry| {
                entry.io = io;
                entry.thread = std.Thread.spawn(.{}, intervalLoop, .{entry}) catch continue;
            }

            const views_idx_ptr: ?*const views_mod.ViewsIndex = if (self.views_index) |*idx| idx else null;

            const worker_ctx = WorkerCtx{
                .io = io,
                .gpa = gpa,
                .listener = &listener,
                .router = &self.router,
                .static_config = self.static_config,
                .views_index = views_idx_ptr,
                .config = self.config,
                .error_handler = self.error_handler,
                ._db = if (self._db) |*d| @as(*const Database, d) else null,
                .decorations = if (@sizeOf(T) == 0) null else @as(*const anyopaque, @ptrCast(&self.decorations)),
                .ws_route_hubs = self.ws_route_hubs.items,
                .sse_hub = if (self.sse_hub) |*h| h else null,
                .global_middlewares = self.global_middlewares[0..self.global_middleware_count],
                .path_middlewares = self.path_middlewares[0..self.path_middleware_count],
                .watchdog = &watchdog,
            };

            workerLoop(worker_ctx);
        }
    };
}

const EmptyDeco = struct {};

fn AppType(comptime T: type) type {
    return Server(T);
}

pub fn server() Server(EmptyDeco) {
    return Server(EmptyDeco).init();
}

pub fn app(decorations: anytype) AppType(@TypeOf(decorations)) {
    if (@hasDecl(@import("spider_config"), "is_default")) {
        std.log.warn(
            "No spider.config.zig found. Running with defaults: views_dir=\"./views\", port=3000, env=development. " ++
                "Runtime template loading may not work without it. " ++
                "Create spider.config.zig in your project root to customize.",
            .{},
        );
    }

    const cfg = @import("../internal/config.zig").fromRoot();
    var s = Server(@TypeOf(decorations)).init();
    s.decorations = decorations;
    s.config = cfg;
    var threaded = std.Io.Threaded.init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();
    if (!ctx_mod.has_embed) {
        // views_index (disk-scan) is only consulted by Ctx.view() when there's
        // no embedded Templates struct — building it when has_embed is true
        // is wasted work, since that branch of view() never reaches vc.index.
        const views_dir = cfg.views_dir orelse "src";
        s.views_index = views_mod.buildIndex(io, std.heap.smp_allocator, views_dir) catch |err| blk: {
            std.log.warn("views index for \"{s}\" not built: {s}", .{ views_dir, @errorName(err) });
            break :blk null;
        };
    }

    health_mod.init();

    if (cfg.env == .development) {
        _ = s.get(livereload_path, livereload.handler, .{});
    }

    // Liveness probe (load balancers, kamal-proxy): no login, not logged on success.
    _ = s.get("/up", health_mod.up, .{ .public = true, .quiet_log = true });
    _ = s.get("/_spider/health", health_mod.health, .{ .public = true, .quiet_log = true });

    return s;
}

pub fn appWithConfig(config: Config) Server(EmptyDeco) {
    var s = Server(EmptyDeco).init();
    s.config = config;
    var threaded = std.Io.Threaded.init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();
    if (!ctx_mod.has_embed) {
        const views_dir = config.views_dir orelse "src";
        s.views_index = views_mod.buildIndex(io, std.heap.smp_allocator, views_dir) catch |err| blk: {
            std.log.warn("views index for \"{s}\" not built: {s}", .{ views_dir, @errorName(err) });
            break :blk null;
        };
    }

    health_mod.init();

    if (config.env == .development) {
        _ = s.get(livereload_path, livereload.handler, .{});
    }

    // Liveness probe (load balancers, kamal-proxy): no login, not logged on success.
    _ = s.get("/up", health_mod.up, .{ .public = true, .quiet_log = true });
    _ = s.get("/_spider/health", health_mod.health, .{ .public = true, .quiet_log = true });

    return s;
}
