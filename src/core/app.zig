const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Ctx = @import("context.zig").Ctx;

const Route = struct {
    method: []const u8,
    path: []const u8,
    handler: *const fn (*Ctx) anyerror!void,
};

const WorkerCtx = struct {
    io: Io,
    gpa: std.mem.Allocator,
    listener: *Io.net.Server,
    routes: []const Route,
};

const ConnCtx = struct {
    stream: Io.net.Stream,
    io: Io,
    gpa: std.mem.Allocator,
    routes: []const Route,
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
            .routes = ctx.routes,
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

    var conn_arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer conn_arena.deinit();

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

        const request = http.receiveHead() catch |err| {
            if (err != error.HttpConnectionClosing) {
                std.debug.print("receiveHead error: {s}\n", .{@errorName(err)});
            }
            break;
        };

        const method = @tagName(request.head.method);
        const path = request.head.target;
        var route_found = false;

        for (ctx.routes) |route| {
            if (std.mem.eql(u8, route.method, method) and
                std.mem.eql(u8, route.path, path))
            {
                var ctx_req = Ctx{ .request = request, .arena = arena };
                route.handler(&ctx_req) catch |err| {
                    std.debug.print("Handler error: {s}\n", .{@errorName(err)});
                };
                route_found = true;
                break;
            }
        }

        if (!route_found) {
            var ctx_req = Ctx{ .request = request, .arena = arena };
            ctx_req.text("404 Not Found") catch {};
        }

        if (!request.head.keep_alive) break;
    }
}

pub const Server = struct {
    spider_arena: std.heap.ArenaAllocator,
    spider_gpa: std.heap.DebugAllocator(.{}),
    allocator: std.mem.Allocator,
    gpa: std.mem.Allocator,
    routes: std.ArrayList(Route),

    pub fn init() Server {
        var self: Server = .{
            .spider_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .spider_gpa = .init,
            .allocator = undefined,
            .gpa = undefined,
            .routes = .empty,
        };
        self.allocator = self.spider_arena.allocator();
        self.gpa = if (builtin.mode == .Debug)
            self.spider_gpa.allocator()
        else
            std.heap.smp_allocator;
        return self;
    }

    pub fn deinit(self: *Server) void {
        self.routes.deinit(self.allocator);
        _ = self.spider_gpa.deinit();
        self.spider_arena.deinit();
    }

    pub fn get(self: *Server, path: []const u8, handler: *const fn (*Ctx) anyerror!void) *Server {
        self.routes.append(self.allocator, .{
            .method = "GET",
            .path = path,
            .handler = handler,
        }) catch unreachable;
        return self;
    }

    pub fn post(self: *Server, path: []const u8, handler: *const fn (*Ctx) anyerror!void) *Server {
        self.routes.append(self.allocator, .{
            .method = "POST",
            .path = path,
            .handler = handler,
        }) catch unreachable;
        return self;
    }

    pub fn listen(self: *Server, port: u16) !void {
        std.debug.print("Speed server starting on port {d}...\n", .{port});

        const gpa = std.heap.smp_allocator;

        var threaded: Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const address = try Io.net.IpAddress.parse("127.0.0.1", port);
        var listener = try address.listen(io, .{ .reuse_address = true });
        defer listener.deinit(io);

        std.debug.print("Server listening on http://127.0.0.1:{d}\n", .{port});

        const cpu_count = std.Thread.getCpuCount() catch 2;
        std.debug.print("Starting {d} worker threads\n", .{cpu_count});

        const threads = try gpa.alloc(std.Thread, cpu_count);
        defer gpa.free(threads);

        const worker_ctx = WorkerCtx{
            .io = io,
            .gpa = gpa,
            .listener = &listener,
            .routes = self.routes.items,
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
    return Server.init();
}
