const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const env = @import("../internal/env.zig");
const static_mod = @import("../modules/static.zig");
pub const StaticConfig = static_mod.StaticConfig;
const ctx_mod = @import("context.zig");
const Ctx = ctx_mod.Ctx;
const Response = ctx_mod.Response;
const MiddlewareFn = ctx_mod.MiddlewareFn;
const ErrorHandler = ctx_mod.ErrorHandler;
const ViewsConfig = ctx_mod.ViewsConfig;
const Database = @import("database.zig").Database;
const DriverType = @import("database.zig").DriverType;
const Router = @import("../routing/router.zig").Router;
const Handler = @import("../routing/router.zig").Handler;
const Config = @import("../internal/config.zig").Config;
const Env = @import("../internal/config.zig").Env;
const default_config = @import("../internal/config.zig").default;
const views_mod = @import("../render/views.zig");
const livereload = @import("../modules/livereload.zig");

// SAFETY: threadlocal is safe here because Io.Threaded uses blocking OS threads —
// each handleConnection occupies one thread exclusively from accept to respond.
// There are no coroutines or fibers, so no two tasks ever interleave on the same
// thread. threadlocal-per-thread == threadlocal-per-connection in this backend.
// WARNING: if Spider migrates to Io.Evented (io_uring with fibers), this breaks —
// multiple tasks on the same thread would interleave and corrupt shared state.
// Fix: store ChainState in Ctx._chain instead of threadlocal.
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

const RouteMiddlewareEntry = struct {
    path: []const u8,
    method: std.http.Method,
    middlewares: []const MiddlewareFn,
};

const PathMiddlewareEntry = struct {
    path: []const u8,
    middleware: MiddlewareFn,
};

fn collectMiddlewares(
    srv: *const Server,
    path: []const u8,
    route_middlewares: []const MiddlewareFn,
    buf: []MiddlewareFn,
) usize {
    var count: usize = 0;

    for (srv.global_middlewares[0..srv.global_middleware_count]) |m| {
        if (count < buf.len) {
            buf[count] = m;
            count += 1;
        }
    }

    for (srv.path_middlewares[0..srv.path_middleware_count]) |entry| {
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
    server: *Server,
    env: Env,
};

const ConnCtx = struct {
    stream: Io.net.Stream,
    io: Io,
    gpa: std.mem.Allocator,
    router: *Router,
    server: *Server,
    env: Env,
};

fn workerLoop(ctx: WorkerCtx) void {
    const tid = std.Thread.getCurrentId();
    std.debug.print("Worker {d} started\n", .{tid});

    var group: std.Io.Group = .init;

    while (true) {
        const stream = ctx.listener.accept(ctx.io) catch |err| {
            std.debug.print("Worker {d} accept error: {s}\n", .{ tid, @errorName(err) });
            break;
        };

        group.concurrent(ctx.io, handleConnection, .{ConnCtx{
            .stream = stream,
            .io = ctx.io,
            .gpa = ctx.gpa,
            .router = ctx.router,
            .server = ctx.server,
            .env = ctx.env,
        }}) catch |err| {
            std.debug.print("Worker {d} concurrent error: {s}\n", .{ tid, @errorName(err) });
            stream.close(ctx.io);
        };
    }

    group.await(ctx.io) catch {};
    std.debug.print("Worker {d} finished\n", .{tid});
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

        // Capture headers before body reading — iterateHeaders() panics after readerExpectNone().
        var headers_map: std.StringHashMapUnmanaged([]const u8) = .{};
        {
            var hdr_iter = request.iterateHeaders();
            while (hdr_iter.next()) |h| {
                headers_map.put(arena, h.name, h.value) catch {};
            }
        }

        // readerExpectNone invalidates head.target; dupe it first so getPath()
        // keeps working in middlewares and handlers after body reading.
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
            if ((static_mod.serve(ctx.io, arena, ctx.server.static_config, path) catch null)) |static_response| {
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

        const views_idx_ptr: ?*const views_mod.ViewsIndex = if (ctx.server.views_index != null)
            &ctx.server.views_index.?
        else
            null;

        const views_cfg: ?ViewsConfig = if (ctx.server.config.views_dir) |vd| ViewsConfig{
            .views_dir = vd,
            .layout = ctx.server.config.layout,
            .io = ctx.io,
            .arena = arena,
            .mode = .runtime,
            .index = views_idx_ptr,
        } else null;

        const match = ctx.router.match(request.head.method, path, arena) catch null;
        const response = if (match) |m| blk: {
            var ctx_req = Ctx{
                .request = request,
                .arena = arena,
                .params = m.params,
                .body = body,
                ._db = if (ctx.server._db) |*d| d else null,
                ._driver_type = ctx.server._driver_type,
                ._views = views_cfg,
                ._io = ctx.io,
                ._stream = ctx.stream,
                ._headers = headers_map,
            };

            var route_mws: []const MiddlewareFn = &.{};
            for (ctx.server.route_middlewares.items) |entry| {
                if (entry.method == request.head.method and std.mem.eql(u8, entry.path, path)) {
                    route_mws = entry.middlewares;
                    break;
                }
            }

            var mw_buf: [64]MiddlewareFn = undefined;
            const mw_count = collectMiddlewares(ctx.server, path, route_mws, &mw_buf);

            break :blk runChain(&ctx_req, mw_buf[0..mw_count], m.handler) catch |err| r: {
                if (ctx.server.error_handler) |eh| {
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
                ._db = if (ctx.server._db) |*db| db else null,
                ._driver_type = ctx.server._driver_type,
                ._views = views_cfg,
                ._io = ctx.io,
                ._stream = ctx.stream,
                ._headers = headers_map,
            };
            break :blk ctx_req.text("404 Not Found", .{ .status = .not_found }) catch
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
        const final_body = response.body orelse "";

        // injetar live reload em dev
        // if (ctx.env == .development) {
        //     const ct = response.content_type;
        //     const is_html = std.mem.startsWith(u8, ct, "text/html");
        //     if (is_html and final_body.len > 0) {
        //         if (std.mem.lastIndexOf(u8, final_body, "</body>")) |idx| {
        //             final_body = std.mem.concat(arena, u8, &.{
        //                 final_body[0..idx],
        //                 livereload.SCRIPT,
        //                 final_body[idx..],
        //             }) catch final_body;
        //         } else {
        //             final_body = std.mem.concat(arena, u8, &.{
        //                 final_body,
        //                 livereload.SCRIPT,
        //             }) catch final_body;
        //         }
        //     }
        // }

        request.respond(final_body, .{
            .status = response.status,
            .extra_headers = extra_headers_buf[0..header_count],
        }) catch {};

        if (!request.head.keep_alive) break;
    }
}

pub const Server = struct {
    spider_arena: std.heap.ArenaAllocator,
    spider_gpa: std.heap.DebugAllocator(.{}),
    allocator: std.mem.Allocator,
    gpa: std.mem.Allocator,
    router: Router,
    global_middlewares: [16]MiddlewareFn = undefined,
    global_middleware_count: usize = 0,
    path_middlewares: [32]PathMiddlewareEntry = undefined,
    path_middleware_count: usize = 0,
    route_middlewares: std.ArrayList(RouteMiddlewareEntry),
    error_handler: ?ErrorHandler = null,
    _db: ?Database = null,
    _driver_type: DriverType = .postgresql,
    static_config: StaticConfig = .{ .dir = "./public", .prefix = "/" },
    config: Config = default_config,
    views_index: ?views_mod.ViewsIndex = null,

    pub fn init() Server {
        env.autoLoad(std.heap.page_allocator);
        env.checkGitignore();

        var self: Server = .{
            .spider_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .spider_gpa = .init,
            .allocator = undefined,
            .gpa = undefined,
            .router = Router.init(std.heap.page_allocator) catch unreachable,
            .global_middleware_count = 0,
            .path_middleware_count = 0,
            .route_middlewares = .empty,
        };
        self.allocator = std.heap.page_allocator;
        self.gpa = if (builtin.mode == .Debug)
            self.spider_gpa.allocator()
        else
            std.heap.smp_allocator;
        return self;
    }

    pub fn deinit(self: *Server) void {
        if (self.views_index) |*idx| idx.deinit();
        self.route_middlewares.deinit(std.heap.page_allocator);
        self.router.deinit();
        _ = self.spider_gpa.deinit();
        self.spider_arena.deinit();
    }

    pub fn use(self: *Server, m: MiddlewareFn) *Server {
        if (self.global_middleware_count < 16) {
            self.global_middlewares[self.global_middleware_count] = m;
            self.global_middleware_count += 1;
        }
        return self;
    }

    pub fn useAt(self: *Server, path: []const u8, m: MiddlewareFn) *Server {
        if (self.path_middleware_count < 32) {
            self.path_middlewares[self.path_middleware_count] = .{ .path = path, .middleware = m };
            self.path_middleware_count += 1;
        }
        return self;
    }

    pub fn onError(self: *Server, handler: ErrorHandler) *Server {
        self.error_handler = handler;
        return self;
    }

    pub fn db(self: *Server, database: Database) *Server {
        self._db = database;
        self._driver_type = database.driver_type;
        return self;
    }

    pub fn staticDir(self: *Server, dir: []const u8) *Server {
        self.static_config = .{ .dir = dir, .prefix = "/" };
        return self;
    }

    pub fn staticAt(self: *Server, dir: []const u8, prefix: []const u8) *Server {
        self.static_config = .{ .dir = dir, .prefix = prefix };
        return self;
    }

    pub fn get(self: *Server, path: []const u8, handler: *const fn (*Ctx) anyerror!Response) *Server {
        self.router.add(.GET, path, handler) catch unreachable;
        return self;
    }

    pub fn post(self: *Server, path: []const u8, handler: *const fn (*Ctx) anyerror!Response) *Server {
        self.router.add(.POST, path, handler) catch unreachable;
        return self;
    }

    pub fn addRoute(
        self: *Server,
        method: std.http.Method,
        path: []const u8,
        middlewares: []const MiddlewareFn,
        handler: Handler,
    ) void {
        self.router.add(method, path, handler) catch {};
        if (middlewares.len > 0) {
            self.route_middlewares.append(std.heap.page_allocator, .{
                .path = path,
                .method = method,
                .middlewares = middlewares,
            }) catch {};
        }
    }

    pub fn group(
        self: *Server,
        prefix: []const u8,
        middlewares: []const MiddlewareFn,
        register: *const fn (*Server, []const u8, []const MiddlewareFn) void,
    ) *Server {
        register(self, prefix, middlewares);
        return self;
    }

    pub const ListenOptions = struct {
        port: ?u16 = null,
        host: ?[]const u8 = null,
    };

    pub fn listen(self: *Server, options: ListenOptions) !void {
        const port = options.port orelse self.config.port;
        const host = options.host orelse self.config.host;

        std.debug.print("Speed server starting on port {d}...\n", .{port});

        const gpa = std.heap.smp_allocator;

        var threaded: Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const address = try Io.net.IpAddress.parse(host, port);
        var listener = try address.listen(io, .{ .reuse_address = true });
        defer listener.deinit(io);

        std.debug.print("Server listening on http://{s}:{d}\n", .{ host, port });

        const cpu_count = std.Thread.getCpuCount() catch 2;
        std.debug.print("Starting {d} worker threads\n", .{cpu_count});

        const threads = try gpa.alloc(std.Thread, cpu_count);
        defer gpa.free(threads);

        const worker_ctx = WorkerCtx{
            .io = io,
            .gpa = gpa,
            .listener = &listener,
            .router = &self.router,
            .server = self,
            .env = self.config.env,
        };

        for (threads) |*t| {
            t.* = std.Thread.spawn(.{}, workerLoop, .{worker_ctx}) catch |err| {
                std.debug.print("Failed to spawn thread: {s}\n", .{@errorName(err)});
                continue;
            };
        }

        for (threads) |t| t.join();
    }
};

pub fn server() Server {
    return Server.init();
}

pub fn app() Server {
    // Warning: without spider.config.zig, Spider runs with defaults that may not
    // match the project structure (e.g. views_dir="./views").
    // Uses @import("root") same as fromRoot() — resolves to the user's main.zig,
    // not Spider's internal root.zig.
    if (@hasDecl(@import("spider_config"), "is_default")) {
        std.debug.print(
            "[spider] WARNING: No spider.config.zig found.\n" ++
                "[spider]          Running with defaults: views_dir=\"./views\", port=3000, env=development.\n" ++
                "[spider]          Runtime template loading may not work without it.\n" ++
                "[spider]          Create spider.config.zig in your project root to customize.\n",
            .{},
        );
    }

    const cfg = @import("../internal/config.zig").fromRoot();
    return appWithConfig(cfg);
}

pub fn appWithConfig(config: Config) Server {
    var s = Server.init();
    s.config = config;
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const views_dir = config.views_dir orelse "src";
    s.views_index = views_mod.buildIndex(io, std.heap.smp_allocator, views_dir) catch null;

    if (config.env == .development) {
        _ = s.get("/_spider/reload", livereload.handler);
    }

    return s;
}
