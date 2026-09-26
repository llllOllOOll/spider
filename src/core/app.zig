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
const rbac = @import("../modules/rbac.zig");

const WsRouteHub = struct {
    handler: Handler,
    hub: *Hub,
    threaded: std.Io.Threaded,
};

threadlocal var chain_middlewares: []const MiddlewareFn = &.{};
threadlocal var chain_handler: ?Handler = null;

fn nextFn(c: *Ctx) anyerror!Response {
    if (chain_middlewares.len == 0) {
        return chain_handler.?(c);
    }
    const m = chain_middlewares[0];
    chain_middlewares = chain_middlewares[1..];
    return m(c, nextFn);
}

fn runChain(c: *Ctx, middlewares: []const MiddlewareFn, handler: Handler) anyerror!Response {
    chain_middlewares = middlewares;
    chain_handler = handler;
    if (middlewares.len == 0) return handler(c);
    chain_middlewares = middlewares[1..];
    return middlewares[0](c, nextFn);
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
};

fn workerLoop(wctx: WorkerCtx) void {
    var group: std.Io.Group = .init;

    while (true) {
        const stream = wctx.listener.accept(wctx.io) catch |err| {
            std.log.err("worker accept error: {s}", .{@errorName(err)});
            break;
        };

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
        }}) catch |err| {
            std.log.err("worker concurrent error: {s}", .{@errorName(err)});
            stream.close(wctx.io);
        };
    }

    group.await(wctx.io) catch {};
}

fn handleConnection(ctx: ConnCtx) error{Canceled}!void {
    defer ctx.stream.close(ctx.io);

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

        var request = http.receiveHead() catch break;

        const target = request.head.target;
        const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;

        var headers_map: std.StringHashMapUnmanaged([]const u8) = .{};
        {
            var hdr_iter = request.iterateHeaders();
            while (hdr_iter.next()) |h| {
                headers_map.put(arena, h.name, h.value) catch {};
            }
        }

        const body: ?[]const u8 = blk: {
            const cl = request.head.content_length orelse break :blk null;
            if (cl == 0) break :blk null;
            const target_copy = arena.dupe(u8, target) catch break :blk null;
            var body_io_buf: [4096]u8 = undefined;
            const body_reader = request.readerExpectNone(&body_io_buf);
            request.head.target = target_copy;
            break :blk body_reader.readAlloc(arena, cl) catch null;
        };

        {
            if ((static_mod.serve(ctx.io, arena, ctx.static_config, path) catch null)) |static_response| {
                var extra_hdrs_buf: [2]std.http.Header = undefined;
                extra_hdrs_buf[0] = .{ .name = "content-type", .value = static_response.content_type };
                request.respond(static_response.body orelse "", .{
                    .status = static_response.status,
                    .extra_headers = extra_hdrs_buf[0..1],
                }) catch {};
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

        const match = ctx.router.match(request.head.method, path, arena) catch null;
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
            };

            var mw_buf: [64]MiddlewareFn = undefined;
            const mw_count = collectMiddlewares(ctx.global_middlewares, ctx.path_middlewares, path, m.middlewares, &mw_buf);

            break :blk runChain(&ctx_req, mw_buf[0..mw_count], m.handler) catch |err| r: {
                if (ctx.error_handler) |eh| {
                    break :r eh(&ctx_req, err) catch Response{
                        .status = .internal_server_error,
                        .body = "Internal Server Error",
                        .content_type = "text/plain",
                    };
                }
                std.log.err("unhandled error: {s}", .{@errorName(err)});
                break :r Response{ .status = .internal_server_error, .body = "Internal Server Error", .content_type = "text/plain" };
            };
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
            };
            var mw_buf_404: [64]MiddlewareFn = undefined;
            const mw_count_404 = collectMiddlewares(ctx.global_middlewares, ctx.path_middlewares, path, &.{}, &mw_buf_404);
            const notFoundHandler: Handler = struct {
                fn h(c: *Ctx) anyerror!Response {
                    return c.text("404 Not Found", .{ .status = .not_found }) catch
                        Response{ .status = .not_found, .body = "404 Not Found", .content_type = "text/plain" };
                }
            }.h;
            break :blk if (mw_count_404 > 0)
                runChain(&ctx_req, mw_buf_404[0..mw_count_404], notFoundHandler) catch |err| r: {
                    if (ctx.error_handler) |eh| {
                        break :r eh(&ctx_req, err) catch Response{
                            .status = .internal_server_error,
                            .body = "Internal Server Error",
                            .content_type = "text/plain",
                        };
                    }
                    break :r Response{ .status = .not_found, .body = "404 Not Found", .content_type = "text/plain" };
                }
            else
                ctx_req.text("404 Not Found", .{ .status = .not_found }) catch
                    Response{ .status = .not_found, .body = "404 Not Found", .content_type = "text/plain" };
        };

        var extra_headers_buf: [32]std.http.Header = undefined;
        var header_count: usize = 0;
        extra_headers_buf[header_count] = .{ .name = "content-type", .value = response.content_type };
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
        }) catch {};

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

// Typed extractors (spider.Path/spider.Form, see core/extractors.zig) are
// recognized by duck-typing on a `spider_kind` decl rather than importing
// extractors.zig directly, so this file doesn't need to know that module
// exists.
fn isExtractor(comptime PT: type) bool {
    return switch (@typeInfo(PT)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(PT, "spider_kind"),
        else => false,
    };
}

// True when `handler`'s parameters require the extractor dispatch path
// (buildAutoWrapper) instead of the classic decoration path (buildWrapper):
// any recognized extractor param, or a *Ctx param anywhere but first.
// Handlers with only *Ctx (at index 0) or only loose decoration types keep
// going through buildWrapper, unchanged.
fn usesExtractors(comptime handler: anytype) bool {
    const fn_info = @typeInfo(@TypeOf(handler)).@"fn";
    inline for (fn_info.param_types, 0..) |maybe_pt, i| {
        const PT = maybe_pt orelse continue;
        if (PT == *Ctx) {
            if (i != 0) return true;
        } else if (isExtractor(PT)) {
            return true;
        }
    }
    return false;
}

// Dispatches handlers using spider.Path(...)/spider.Form(...) params (mixed
// with *Ctx, in any order, no 4-param ceiling — unlike buildWrapper). Each
// extractor resolves itself from `ctx`; on failure the wrapper returns a
// fixed 400 response immediately, without calling the handler.
fn buildAutoWrapper(comptime handler: anytype) Handler {
    const fn_info = @typeInfo(@TypeOf(handler)).@"fn";

    const W = struct {
        pub fn call(ctx: *Ctx) anyerror!Response {
            var args: std.meta.ArgsTuple(@TypeOf(handler)) = undefined;

            inline for (fn_info.param_types, 0..) |maybe_pt, i| {
                const PT = maybe_pt orelse @compileError("generic param not supported");

                if (PT == *Ctx) {
                    args[i] = ctx;
                } else if (comptime isExtractor(PT)) {
                    if (PT.spider_kind == .path) {
                        const raw = ctx.params.get(PT.param_name) orelse return ctx.text(
                            "missing path param: " ++ PT.param_name,
                            .{ .status = .bad_request },
                        );
                        if (comptime PT.Inner == []const u8) {
                            args[i] = .{ .value = raw };
                        } else {
                            const parsed = std.fmt.parseInt(PT.Inner, raw, 10) catch return ctx.text(
                                "invalid path param: " ++ PT.param_name,
                                .{ .status = .bad_request },
                            );
                            args[i] = .{ .value = parsed };
                        }
                    } else if (PT.spider_kind == .form) {
                        const parsed = ctx.parseForm(PT.Inner) catch |err| return ctx.text(
                            @errorName(err),
                            .{ .status = .bad_request },
                        );
                        args[i] = .{ .value = parsed };
                    } else {
                        @compileError("unsupported spider extractor kind on " ++ @typeName(PT));
                    }
                } else {
                    @compileError(
                        "buildAutoWrapper only supports *Ctx and extractor params " ++
                            "(spider.Path(...), spider.Form(...)); handler parameter `" ++
                            @typeName(PT) ++ "` is neither. For loose-type decoration " ++
                            "parameters, use the classic fn(*Ctx, T) !Response signature instead.",
                    );
                }
            }

            return @call(.auto, handler, args);
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
            try hub.add(.{ .id = conn_id, .stream = ctx._stream });
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
        ) catch {};
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
        interval_threads: std.ArrayListUnmanaged(IntervalEntry) = .empty,

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
                .middlewares = comptime rbac.routeMiddlewares(config),
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
                .middlewares = comptime rbac.routeMiddlewares(config),
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
                .middlewares = comptime rbac.routeMiddlewares(config),
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
                .middlewares = comptime rbac.routeMiddlewares(config),
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
                .middlewares = comptime rbac.routeMiddlewares(config),
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
                .middlewares = comptime rbac.routeMiddlewares(config),
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
            }) catch {};
            return self;
        }

        // Lazily creates the server's single shared SSE hub. Idempotent —
        // safe to call from .sse(), .sseInterval(), and mount() (when a
        // mounted Group has SSE routes of its own).
        //
        // Uses a real, dedicated Io.Threaded — not .init_single_threaded,
        // which is a static stub (.allocator = .failing, .concurrent_limit
        // = .nothing) documented as never coordinating real concurrency.
        // The Hub's mutex/sleep/timestamp calls ARE exercised concurrently
        // for real (one call path per live SSE connection, each running
        // under the main server's Io), so they need an Io whose Mutex is
        // actually safe to contend on from multiple threads. This instance
        // never calls .async()/.concurrent() (Hub only uses blocking sync
        // primitives), so a real Io.Threaded here spawns no extra worker
        // threads in practice — it's decoupled from whichever io_backend
        // the main Server.listen() uses, which is fine: SSE's own
        // synchronization doesn't need to match it.
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
            }) catch {};
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
            if (self.sse_hub) |*hub| hub.startHeartbeat(interval_ms) catch {};
            return self;
        }

        /// Starts the shared SSE hub's proactive dead-connection sweep —
        /// independent of sseHeartbeat, so a channel that's both quiet and
        /// never emitted to doesn't accumulate zombie connections
        /// indefinitely. `interval_ms` null uses Hub.default_sweep_ms (60s).
        pub fn sseSweep(self: *Self, interval_ms: ?u64) *Self {
            self.ensureSseHub();
            if (self.sse_hub) |*hub| hub.startSweep(interval_ms) catch {};
            return self;
        }

        pub fn sse(self: *Self, path: []const u8, comptime handler: fn (*Sse) anyerror!void) *Self {
            self.ensureSseHub();
            const H = sse_mod.buildHandler(handler);
            self.router.add(.GET, path, H) catch unreachable;
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
            self.router.addRoute(method, path, .{ .handler = handler, .middlewares = middlewares }) catch {};
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

        pub fn mount(self: *Self, child: Group) *Self {
            child.router.forEach(std.heap.page_allocator, self, struct {
                fn cb(s: *Self, method: std.http.Method, path: []const u8, route: Route) void {
                    s.router.addRoute(method, path, route) catch {};
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

        pub fn listen(self: *Self, options: ListenOptions) !void {
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
        s.views_index = views_mod.buildIndex(io, std.heap.smp_allocator, views_dir) catch null;
    }

    health_mod.init();

    if (cfg.env == .development) {
        _ = s.get("/_spider/reload", livereload.handler, .{});
    }

    _ = s.get("/up", health_mod.up, .{});
    _ = s.get("/_spider/health", health_mod.health, .{});

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
        s.views_index = views_mod.buildIndex(io, std.heap.smp_allocator, views_dir) catch null;
    }

    health_mod.init();

    if (config.env == .development) {
        _ = s.get("/_spider/reload", livereload.handler, .{});
    }

    _ = s.get("/up", health_mod.up, .{});
    _ = s.get("/_spider/health", health_mod.health, .{});

    return s;
}
