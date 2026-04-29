const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Ctx = @import("context.zig").Ctx;
const Response = @import("context.zig").Response;
const Router = @import("../routing/router.zig").Router;

const WorkerCtx = struct {
    io: Io,
    gpa: std.mem.Allocator,
    listener: *Io.net.Server,
    router: *Router,
};

const ConnCtx = struct {
    stream: Io.net.Stream,
    io: Io,
    gpa: std.mem.Allocator,
    router: *Router,
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

        var request = http.receiveHead() catch |err| {
            if (err != error.HttpConnectionClosing) {
                std.debug.print("receiveHead error: {s}\n", .{@errorName(err)});
            }
            break;
        };

        const target = request.head.target;
        const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;

        const body: ?[]const u8 = blk: {
            const cl = request.head.content_length orelse break :blk null;
            if (cl == 0) break :blk null;
            var body_io_buf: [4096]u8 = undefined;
            const body_reader = request.readerExpectNone(&body_io_buf);
            break :blk body_reader.readAlloc(arena, cl) catch null;
        };

        const match = ctx.router.match(request.head.method, path, arena) catch null;
        const response = if (match) |m| blk: {
            var ctx_req = Ctx{ .request = request, .arena = arena, .params = m.params, .body = body };
            break :blk m.handler(&ctx_req) catch |err| r: {
                std.debug.print("Handler error: {s}\n", .{@errorName(err)});
                break :r Response{ .status = .internal_server_error, .body = "Internal Server Error", .content_type = "text/plain" };
            };
        } else blk: {
            var ctx_req = Ctx{ .request = request, .arena = arena, .params = .{}, .body = body };
            break :blk ctx_req.text("404 Not Found", .{ .status = .not_found }) catch
                Response{ .status = .not_found, .body = "404 Not Found", .content_type = "text/plain" };
        };

        var extra_headers_buf: [18]std.http.Header = undefined;
        var header_count: usize = 0;
        extra_headers_buf[header_count] = .{ .name = "content-type", .value = response.content_type };
        header_count += 1;
        for (response.headers) |h| {
            if (header_count < 18) {
                extra_headers_buf[header_count] = .{ .name = h[0], .value = h[1] };
                header_count += 1;
            }
        }
        request.respond(response.body orelse "", .{
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

    pub fn init() Server {
        var self: Server = .{
            .spider_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .spider_gpa = .init,
            .allocator = undefined,
            .gpa = undefined,
            .router = Router.init(std.heap.page_allocator) catch unreachable,
        };
        self.allocator = self.spider_arena.allocator();
        self.gpa = if (builtin.mode == .Debug)
            self.spider_gpa.allocator()
        else
            std.heap.smp_allocator;
        return self;
    }

    pub fn deinit(self: *Server) void {
        self.router.deinit();
        _ = self.spider_gpa.deinit();
        self.spider_arena.deinit();
    }

    pub fn get(self: *Server, path: []const u8, handler: *const fn (*Ctx) anyerror!Response) *Server {
        self.router.add(.GET, path, handler) catch unreachable;
        return self;
    }

    pub fn post(self: *Server, path: []const u8, handler: *const fn (*Ctx) anyerror!Response) *Server {
        self.router.add(.POST, path, handler) catch unreachable;
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
            .router = &self.router,
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
