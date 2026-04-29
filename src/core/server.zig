const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const web = @import("../web.zig");
const websocket = @import("../ws/websocket.zig");
const spider = @import("../spider.zig");
const logger = @import("../internal/logger.zig");
const metrics = @import("../internal/metrics.zig");
const pipeline = @import("pipeline.zig");

const log = logger.Logger.init(.info);

pub const MAX_BODY_SIZE: u64 = 1 * 1024 * 1024;
pub const RETAIN_BYTES: usize = 8192;
pub const SLOW_REQUEST_THRESHOLD_NS: u64 = 500 * 1000 * 1000; // 500ms in nanoseconds

pub var shutdown_flag = std.atomic.Value(bool).init(false);
pub var ws_counter = std.atomic.Value(u64).init(0);
pub var active_connections = std.atomic.Value(usize).init(0);

pub const ConnectionContext = struct {
    stream: net.Stream,
    io: Io,
    allocator: std.mem.Allocator,
    router: *std.StringHashMap(HandlerFn),
    static_dir: []const u8,
    app: ?*web.App,
    conn_arena: *std.heap.ArenaAllocator,
    req_arena: *std.heap.ArenaAllocator,
};

pub const HandlerFn = *const fn (req: *std.http.Server.Request, allocator: std.mem.Allocator) anyerror!void;

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
            .listener = try net.IpAddress.listen(&address, io, .{ .reuse_address = true }),
            .router = std.StringHashMap(HandlerFn).init(allocator),
            .static_dir = static_dir,
            .app = null,
            .port = port,
        };

        try self.router.put("/", pipeline.indexHandler);
        try self.router.put("/metric", pipeline.metricHandler);
        try self.router.put("/health", pipeline.healthHandler);

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
        log.info("Generals gathered in their masses — server rising on port | uptime since 11110110011", .{ .port = self.port });
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

            group.concurrent(self.io, pipeline.handleConnection, .{ctx}) catch |err| {
                log.warn("concurrent_error", .{ .err = @errorName(err) });
                stream.close(self.io);
                ctx.conn_arena.deinit();
                ctx.req_arena.deinit();
                self.allocator.destroy(ctx.conn_arena);
                self.allocator.destroy(ctx.req_arena);
                self.allocator.destroy(ctx);
            };
        }
        log.info("shutting_down", .{});
        const shutdown_timeout_ns = 10 * 1000 * 1000 * 1000;
        const start_time = std.Io.Clock.now(.awake, self.io);
        while (active_connections.load(.acquire) > 0) {
            const elapsed = start_time.durationTo(std.Io.Clock.now(.awake, self.io));
            if (elapsed.toNanoseconds() > shutdown_timeout_ns) {
                log.warn("Forced shutdown with {} active connections", .{active_connections.load(.acquire)});
                break;
            }
            std.Io.sleep(self.io, std.Io.Duration.fromNanoseconds(100 * 1000 * 1000), .awake) catch {};
        }
        group.await(self.io) catch {};
        log.info("Shutdown complete", .{});
    }
};

pub fn setupSignalHandlers() void {
    var act = std.posix.Sigaction{
        .handler = .{ .handler = &handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

pub fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    shutdown_flag.store(true, .release);
}
