const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const net = std.Io.net;
const web = @import("web.zig");

const BUFFER_SIZE = 4096;

pub const Connection = struct {
    stream: net.Stream,
    io: std.Io,
    allocator: Allocator,
    app: ?*web.App,
    next: ?*Connection,
};

const Queue = struct {
    first: ?*Connection = null,
    last: ?*Connection = null,
    lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn acquireLock(self: *Queue) void {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            Thread.yield() catch {};
        }
    }

    fn releaseLock(self: *Queue) void {
        self.lock.store(false, .release);
    }

    fn push(self: *Queue, conn: *Connection) void {
        self.acquireLock();
        defer self.releaseLock();
        conn.next = null;
        if (self.last) |last| {
            last.next = conn;
        } else {
            self.first = conn;
        }
        self.last = conn;
    }

    fn pop(self: *Queue) ?*Connection {
        self.acquireLock();
        defer self.releaseLock();
        const conn = self.first orelse return null;
        self.first = conn.next;
        if (self.first == null) self.last = null;
        return conn;
    }
};

const Worker = struct {
    queue: Queue,
    arena: std.heap.ArenaAllocator,
    read_buffer: [BUFFER_SIZE]u8,
    write_buffer: [BUFFER_SIZE]u8,
    thread: ?Thread,
    running: std.atomic.Value(usize),

    fn init(allocator: Allocator) !Worker {
        return .{
            .queue = Queue{},
            .arena = std.heap.ArenaAllocator.init(allocator),
            .read_buffer = undefined,
            .write_buffer = undefined,
            .thread = null,
            .running = std.atomic.Value(usize).init(1),
        };
    }

    fn deinit(self: *Worker) void {
        self.arena.deinit();
    }
};

pub const ThreadPool = struct {
    threads: []Thread,
    workers: []Worker,
    allocator: Allocator,
    next_worker: std.atomic.Value(usize),

    pub fn init(allocator: Allocator, thread_count: usize) !ThreadPool {
        const threads = try allocator.alloc(Thread, thread_count);
        const workers = try allocator.alloc(Worker, thread_count);

        for (0..thread_count) |i| {
            workers[i] = try Worker.init(allocator);
            workers[i].running.store(1, .monotonic);
            threads[i] = try Thread.spawn(.{}, workerLoop, .{&workers[i]});
        }

        return .{
            .threads = threads,
            .workers = workers,
            .allocator = allocator,
            .next_worker = std.atomic.Value(usize).init(0),
        };
    }

    pub fn deinit(self: *ThreadPool) void {
        for (self.workers) |*worker| worker.running.store(0, .monotonic);
        for (self.threads) |thread| thread.join();
        for (self.workers) |*worker| worker.deinit();
        self.allocator.free(self.workers);
        self.allocator.free(self.threads);
    }

    pub fn dispatch(self: *ThreadPool, conn: *Connection) void {
        const idx = self.next_worker.fetchAdd(1, .monotonic) % self.workers.len;
        self.workers[idx].queue.push(conn);
    }
};

fn workerLoop(worker: *Worker) void {
    while (worker.running.load(.monotonic) != 0) {
        const conn = worker.queue.pop() orelse {
            Thread.yield() catch {};
            continue;
        };
        defer {
            conn.stream.close(conn.io);
            _ = worker.arena.reset(.free_all);
        }
        handleConnection(conn, &worker.arena, &worker.read_buffer, &worker.write_buffer);
    }
}

fn translateMethod(std_method: std.http.Method) web.Method {
    return switch (std_method) {
        .GET => .get,
        .POST => .post,
        .PUT => .put,
        .PATCH => .patch,
        .DELETE => .delete,
        .OPTIONS => .options,
        .HEAD => .head,
        else => .get,
    };
}

fn handleConnection(conn: *Connection, arena: *std.heap.ArenaAllocator, read_buffer: *[BUFFER_SIZE]u8, write_buffer: *[BUFFER_SIZE]u8) void {
    var stream_reader = net.Stream.Reader.init(conn.stream, conn.io, read_buffer);
    var stream_writer = net.Stream.Writer.init(conn.stream, conn.io, write_buffer);
    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    while (true) {
        _ = arena.reset(.free_all);
        const allocator = arena.allocator();

        var std_req = http_server.receiveHead() catch return;

        const app = conn.app orelse break;

        const url = std_req.head.target;
        var web_req = web.Request{
            .method = translateMethod(std_req.head.method),
            .path = if (std.mem.indexOfScalar(u8, url, '?')) |q| url[0..q] else url,
            .query = if (std.mem.indexOfScalar(u8, url, '?')) |q| url[q + 1 ..] else null,
            .headers = web.Headers.init(),
            .body = null,
            .params = .{},
        };

        const web_res = app.dispatch(allocator, &web_req) catch return;

        var extra_headers: [16]std.http.Header = undefined;
        var header_count: usize = 0;
        var hit = web_res.headers.map.iterator();
        while (hit.next()) |entry| {
            if (header_count < 16) {
                extra_headers[header_count] = .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* };
                header_count += 1;
            }
        }

        std_req.respond(web_res.body orelse "", .{
            .status = @enumFromInt(@intFromEnum(web_res.status)),
            .extra_headers = extra_headers[0..header_count],
        }) catch return;

        if (!std_req.head.keep_alive) break;
    }
}
