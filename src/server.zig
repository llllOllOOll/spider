const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const Thread = std.Thread;
const web = @import("web.zig");

const index_html = @embedFile("index.html");

const MAX_BODY_SIZE: u64 = 1 * 1024 * 1024;
const THREAD_COUNT = 32;
const REQUEST_BUFFER_SIZE = 4096;
const LARGE_BUFFER_SIZE = 64 * 1024;
const LARGE_BUFFER_COUNT = 16;
const MIN_CONN = 64;
const RETAIN_BYTES = 4096;

const BufferPool = struct {
    buffers: [][]u8,
    available: []std.atomic.Value(bool),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !*BufferPool {
        const pool = try allocator.create(BufferPool);
        pool.allocator = allocator;
        pool.buffers = try allocator.alloc([]u8, LARGE_BUFFER_COUNT);
        for (pool.buffers) |*buf| {
            buf.* = try allocator.alloc(u8, LARGE_BUFFER_SIZE);
        }
        pool.available = try allocator.alloc(std.atomic.Value(bool), LARGE_BUFFER_COUNT);
        for (pool.available) |*a| {
            a.* = std.atomic.Value(bool).init(true);
        }
        return pool;
    }

    fn deinit(self: *BufferPool) void {
        for (self.buffers) |buf| self.allocator.free(buf);
        self.allocator.free(self.buffers);
        self.allocator.free(self.available);
        self.allocator.destroy(self);
    }

    fn acquire(self: *BufferPool) ?[]u8 {
        for (0..self.available.len) |i| {
            if (self.available[i].cmpxchgWeak(true, false, .acquire, .monotonic) == null) {
                return self.buffers[i];
            }
        }
        return null;
    }

    fn release(self: *BufferPool, buf: []u8) void {
        for (self.buffers, 0..) |b, i| {
            if (b.ptr == buf.ptr) {
                self.available[i].store(true, .release);
                return;
            }
        }
    }
};

const Connection = struct {
    stream: net.Stream,
    io: Io,
    allocator: std.mem.Allocator,
    conn_arena: *std.heap.ArenaAllocator,
    req_arena: *std.heap.ArenaAllocator,
    read_buffer: [REQUEST_BUFFER_SIZE]u8,
    large_buffer: ?[]u8 = null,
    buffer_pool: *BufferPool,
    app: ?*web.App,
    router: *std.StringHashMap(HandlerFn),
    static_dir: []const u8,

    fn init(allocator: std.mem.Allocator, buffer_pool: *BufferPool) !Connection {
        const conn_arena_ptr = try allocator.create(std.heap.ArenaAllocator);
        conn_arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
        const req_arena_ptr = try allocator.create(std.heap.ArenaAllocator);
        req_arena_ptr.* = std.heap.ArenaAllocator.init(allocator);

        return .{
            .stream = undefined,
            .io = undefined,
            .allocator = allocator,
            .conn_arena = conn_arena_ptr,
            .req_arena = req_arena_ptr,
            .read_buffer = undefined,
            .large_buffer = null,
            .buffer_pool = buffer_pool,
            .app = null,
            .router = undefined,
            .static_dir = undefined,
        };
    }

    fn deinit(self: *Connection) void {
        if (self.large_buffer) |buf| self.buffer_pool.release(buf);
        self.req_arena.deinit();
        self.conn_arena.deinit();
        self.allocator.destroy(self.req_arena);
        self.allocator.destroy(self.conn_arena);
    }

    fn reset(self: *Connection) void {
        if (self.large_buffer) |buf| {
            self.buffer_pool.release(buf);
            self.large_buffer = null;
        }
        _ = self.req_arena.reset(.{ .retain_with_limit = RETAIN_BYTES });
    }
};

const HandlerFn = *const fn (req: *std.http.Server.Request, allocator: std.mem.Allocator) anyerror!void;

const ConnectionPool = struct {
    connections: []Connection,
    available: usize,
    allocator: std.mem.Allocator,
    buffer_pool: *BufferPool,
    lock: std.atomic.Value(bool),

    fn init(allocator: std.mem.Allocator) !*ConnectionPool {
        const pool = try allocator.create(ConnectionPool);
        pool.allocator = allocator;
        pool.buffer_pool = try BufferPool.init(allocator);
        pool.connections = try allocator.alloc(Connection, MIN_CONN);
        for (pool.connections) |*conn| {
            conn.* = try Connection.init(allocator, pool.buffer_pool);
        }
        pool.available = MIN_CONN;
        pool.lock = std.atomic.Value(bool).init(false);
        return pool;
    }

    fn deinit(self: *ConnectionPool) void {
        for (self.connections) |*conn| conn.deinit();
        self.allocator.free(self.connections);
        self.buffer_pool.deinit();
        self.allocator.destroy(self);
    }

    fn acquire(self: *ConnectionPool) ?*Connection {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            Thread.yield() catch {};
        }
        defer self.lock.store(false, .release);
        if (self.available == 0) return null;
        self.available -= 1;
        return &self.connections[self.available];
    }

    fn release(self: *ConnectionPool, conn: *Connection) void {
        conn.reset();
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            Thread.yield() catch {};
        }
        defer self.lock.store(false, .release);
        self.available += 1;
    }
};

const Task = struct {
    conn: *Connection,
    next: ?*Task = null,
};

const ThreadPool = struct {
    threads: []Thread,
    queue: Queue,
    conn_pool: *ConnectionPool,
    running: std.atomic.Value(bool),
    allocator: std.mem.Allocator,

    const Queue = struct {
        first: ?*Task = null,
        last: ?*Task = null,
        lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn push(self: *Queue, task: *Task) void {
            while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
                Thread.yield() catch {};
            }
            defer self.lock.store(false, .release);
            task.next = null;
            if (self.last) |last| {
                last.next = task;
            } else {
                self.first = task;
            }
            self.last = task;
        }

        fn pop(self: *Queue) ?*Task {
            while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
                Thread.yield() catch {};
            }
            defer self.lock.store(false, .release);
            const task = self.first orelse return null;
            self.first = task.next;
            if (self.first == null) self.last = null;
            return task;
        }
    };

    fn init(allocator: std.mem.Allocator, thread_count: usize, conn_pool: *ConnectionPool) !ThreadPool {
        const threads = try allocator.alloc(Thread, thread_count);
        var pool: ThreadPool = .{
            .threads = threads,
            .allocator = allocator,
            .queue = .{},
            .conn_pool = conn_pool,
            .running = std.atomic.Value(bool).init(true),
        };
        for (threads) |*t| {
            t.* = try Thread.spawn(.{}, workerLoop, .{&pool});
        }
        return pool;
    }

    fn deinit(self: *ThreadPool) void {
        self.running.store(false, .release);
        for (self.threads) |t| t.join();
        self.allocator.free(self.threads);
    }

    fn submit(self: *ThreadPool, task: *Task) void {
        self.queue.push(task);
    }
};

fn workerLoop(pool: *ThreadPool) void {
    while (pool.running.load(.acquire)) {
        const task = pool.queue.pop() orelse {
            Thread.yield() catch {};
            continue;
        };
        handleConnection(task.conn);
    }
}

fn handleConnection(conn: *Connection) void {
    defer {
        conn.stream.close(conn.io);
    }

    var write_buffer: [REQUEST_BUFFER_SIZE]u8 = undefined;
    var stream_reader = net.Stream.Reader.init(conn.stream, conn.io, &conn.read_buffer);
    var stream_writer = net.Stream.Writer.init(conn.stream, conn.io, &write_buffer);
    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    while (true) {
        _ = conn.req_arena.reset(.{ .retain_with_limit = RETAIN_BYTES });

        var request = http_server.receiveHead() catch {
            break;
        };

        if (request.head.content_length) |len| {
            if (len > MAX_BODY_SIZE) {
                _ = request.respond("413 Payload Too Large", .{
                    .status = .payload_too_large,
                }) catch {};
                break;
            }
            if (len > conn.read_buffer.len and conn.large_buffer == null) {
                conn.large_buffer = conn.buffer_pool.acquire();
                if (conn.large_buffer) |buf| {
                    stream_reader = net.Stream.Reader.init(conn.stream, conn.io, buf);
                }
            }
        }

        const allocator = conn.req_arena.allocator();
        const path = request.head.target;

        if (conn.app) |app| {
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
            const handler = conn.router.get(path);
            if (handler) |h| {
                h(&request, allocator) catch break;
            } else {
                const full_path = std.fs.path.join(allocator, &.{ conn.static_dir, path }) catch {
                    break;
                };
                defer allocator.free(full_path);
                const file_content = std.Io.Dir.cwd().readFileAlloc(conn.io, full_path, allocator, .unlimited) catch {
                    _ = request.respond("404 Not Found", .{
                        .status = .not_found,
                    }) catch {};
                    continue;
                };
                defer allocator.free(file_content);
                const content_type = getMimeType(full_path);
                request.respond(file_content, .{
                    .status = .ok,
                    .extra_headers = &.{.{ .name = "content-type", .value = content_type }},
                }) catch break;
            }
        }

        if (!request.head.keep_alive) break;
    }
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

pub const Server = struct {
    io: Io,
    listener: net.Server,
    allocator: std.mem.Allocator,
    router: std.StringHashMap(HandlerFn),
    static_dir: []const u8,
    app: ?*web.App,
    conn_pool: *ConnectionPool,
    thread_pool: ThreadPool,

    pub fn init(allocator: std.mem.Allocator, io: Io, port: u16, static_dir: []const u8) !*Server {
        const self = try allocator.create(Server);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .listener = try net.IpAddress.listen(net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) }, io, .{ .reuse_address = true }),
            .router = std.StringHashMap(HandlerFn).init(allocator),
            .static_dir = static_dir,
            .app = null,
            .conn_pool = try ConnectionPool.init(allocator),
            .thread_pool = undefined,
        };

        try self.router.put("/", indexHandler);
        try self.router.put("/metric", metricHandler);

        self.thread_pool = try ThreadPool.init(allocator, THREAD_COUNT, self.conn_pool);

        return self;
    }

    pub fn deinit(self: *Server) void {
        self.router.deinit();
        self.thread_pool.deinit();
        self.conn_pool.deinit();
        self.listener.deinit(self.io);
        self.allocator.destroy(self);
    }

    pub fn setApp(self: *Server, app: *web.App) void {
        self.app = app;
    }

    pub fn start(self: *Server) !void {
        std.debug.print("Server listening on port 8080 (thread pool)\n", .{});
        while (true) {
            const stream = self.listener.accept(self.io) catch |err| {
                std.debug.print("Accept error: {}\n", .{err});
                continue;
            };

            const conn = self.conn_pool.acquire() orelse {
                stream.close(self.io);
                continue;
            };

            conn.stream = stream;
            conn.io = self.io;
            conn.app = self.app;
            conn.router = &self.router;
            conn.static_dir = self.static_dir;

            var task = self.allocator.create(Task) catch {
                stream.close(self.io);
                self.conn_pool.release(conn);
                continue;
            };
            task.conn = conn;
            self.thread_pool.submit(task);
        }
    }
};

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

pub fn start(allocator: std.mem.Allocator, io: std.Io) !void {
    var server = try Server.init(allocator, io, 8080, "src/static");
    defer server.deinit();
    try server.start();
}
