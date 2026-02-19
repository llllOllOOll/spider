const std = @import("std");
const Io = std.Io;
const Thread = std.Thread;
const net = std.Io.net;

const BUFFER_SIZE = 8192;
const DEFAULT_THREAD_COUNT = 32;
const DEFAULT_BACKLOG = 500;

const Task = struct {
    conn: *Connection,
};

const Connection = struct {
    stream: net.Stream,
    io: Io,
    arena: std.heap.ArenaAllocator,
    buffer_pool: *BufferPool,
};

const BufferPool = struct {
    buffers: [][]u8,
    available: []bool,
    mutex: std.Io.Mutex,
    allocator: std.mem.Allocator,
    buffer_size: usize,

    fn init(allocator: std.mem.Allocator, count: usize, size: usize) !BufferPool {
        const buffers = try allocator.alloc([]u8, count);
        for (buffers) |*buf| {
            buf.* = try allocator.alloc(u8, size);
        }
        const available = try allocator.alloc(bool, count);
        @memset(available, true);
        return .{
            .buffers = buffers,
            .available = available,
            .mutex = std.Io.Mutex.init,
            .allocator = allocator,
            .buffer_size = size,
        };
    }

    fn deinit(self: *BufferPool) void {
        for (self.buffers) |buf| {
            self.allocator.free(buf);
        }
        self.allocator.free(self.buffers);
        self.allocator.free(self.available);
    }

    fn acquire(self: *BufferPool) ?[]u8 {
        self.mutex.lock() catch return null;
        defer self.mutex.unlock();
        for (self.available, 0..) |avail, i| {
            if (avail) {
                self.available[i] = false;
                return self.buffers[i];
            }
        }
        return null;
    }

    fn release(self: *BufferPool, buf: []u8) void {
        self.mutex.lock() catch return;
        defer self.mutex.unlock();
        for (self.buffers, 0..) |b, i| {
            if (b.ptr == buf.ptr) {
                self.available[i] = true;
                return;
            }
        }
    }
};

const ThreadPool = struct {
    threads: []Thread,
    allocator: std.mem.Allocator,
    queue: Queue,
    buffer_pool: *BufferPool,
    running: std.atomic.Value(bool),

    const Queue = struct {
        first: ?*Task = null,
        last: ?*Task = null,
        lock: std.Io.Mutex = .{},
        cond: std.Io.Condition = .{},

        fn push(self: *Queue, task: *Task) void {
            self.lock.lock() catch return;
            defer self.lock.unlock();
            task.conn = undefined;
            if (self.last) |last| {
                last.next = task;
            } else {
                self.first = task;
            }
            self.last = task;
            self.cond.signal();
        }

        fn pop(self: *Queue) ?*Task {
            self.lock.lock() catch return null;
            defer self.lock.unlock();
            while (self.first == null) {
                self.cond.wait(&self.lock);
            }
            const task = self.first.?;
            self.first = task.next;
            if (self.first == null) self.last = null;
            return task;
        }
    };

    fn init(allocator: std.mem.Allocator, thread_count: usize, buffer_pool: *BufferPool) !ThreadPool {
        const threads = try allocator.alloc(Thread, thread_count);
        var pool: ThreadPool = .{
            .threads = threads,
            .allocator = allocator,
            .queue = .{},
            .buffer_pool = buffer_pool,
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
        const task = pool.queue.pop() orelse continue;
        handleConnection(task.conn);
    }
}

fn handleConnection(conn: *Connection) void {
    defer {
        conn.stream.close(conn.io);
        conn.arena.deinit();
        conn.allocator.destroy(conn);
    }

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;

    var stream_reader = net.Stream.Reader.init(conn.stream, conn.io, &read_buffer);
    var stream_writer = net.Stream.Writer.init(conn.stream, conn.io, &write_buffer);

    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    while (true) {
        _ = conn.arena.reset(.{ .retain_with_limit = 4096 });

        const request = http_server.receiveHead() catch break;
        if (!request.head.keep_alive) break;
    }
}
