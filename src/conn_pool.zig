const std = @import("std");
const net = std.Io.net;
const Io = std.Io;
const http = std.http;

const MIN_CONN = 64;
const REQUEST_BUFFER_SIZE = 4096;
const LARGE_BUFFER_SIZE = 64 * 1024;
const LARGE_BUFFER_COUNT = 16;
const RETAIN_ALLOCATED_BYTES = 4096;

const BufferPool = struct {
    buffers: [][]u8,
    available: []bool,
    mutex: std.Io.Mutex,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !*BufferPool {
        const pool = try allocator.create(BufferPool);
        pool.allocator = allocator;
        pool.buffers = try allocator.alloc([]u8, LARGE_BUFFER_COUNT);
        for (pool.buffers) |*buf| {
            buf.* = try allocator.alloc(u8, LARGE_BUFFER_SIZE);
        }
        pool.available = try allocator.alloc(bool, LARGE_BUFFER_COUNT);
        @memset(pool.available, true);
        pool.mutex = .init;
        return pool;
    }

    fn deinit(self: *BufferPool) void {
        for (self.buffers) |buf| self.allocator.free(buf);
        self.allocator.free(self.buffers);
        self.allocator.free(self.available);
        self.allocator.destroy(self);
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

pub const Connection = struct {
    stream: net.Stream,
    io: Io,
    allocator: std.mem.Allocator,
    conn_arena: *std.heap.ArenaAllocator,
    req_arena: *std.heap.ArenaAllocator,
    read_buffer: [REQUEST_BUFFER_SIZE]u8,
    large_buffer: ?[]u8 = null,
    buffer_pool: *BufferPool,

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
        };
    }

    fn deinit(self: *Connection) void {
        if (self.large_buffer) |buf| {
            self.buffer_pool.release(buf);
        }
        self.req_arena.deinit();
        self.conn_arena.deinit();
        self.allocator.destroy(&self.req_arena);
        self.allocator.destroy(&self.conn_arena);
    }

    fn reset(self: *Connection) void {
        if (self.large_buffer) |buf| {
            self.buffer_pool.release(buf);
            self.large_buffer = null;
        }
        _ = self.req_arena.reset(.{ .retain_with_limit = RETAIN_ALLOCATED_BYTES });
    }

    fn allocator(self: *Connection) std.mem.Allocator {
        return self.req_arena.allocator();
    }
};

pub const ConnectionPool = struct {
    connections: []Connection,
    available: usize,
    allocator: std.mem.Allocator,
    buffer_pool: *BufferPool,
    mutex: std.Io.Mutex,

    fn init(allocator: std.mem.Allocator) !*ConnectionPool {
        const pool = try allocator.create(ConnectionPool);
        pool.allocator = allocator;
        pool.buffer_pool = try BufferPool.init(allocator);

        pool.connections = try allocator.alloc(Connection, MIN_CONN);
        for (pool.connections) |*conn| {
            conn.* = try Connection.init(allocator, pool.buffer_pool);
        }

        pool.available = MIN_CONN;
        pool.mutex = .init;
        return pool;
    }

    fn deinit(self: *ConnectionPool) void {
        for (self.connections) |*conn| conn.deinit();
        self.allocator.free(self.connections);
        self.buffer_pool.deinit();
        self.allocator.destroy(self);
    }

    fn acquire(self: *ConnectionPool) ?*Connection {
        self.mutex.lock() catch return null;
        defer self.mutex.unlock();
        if (self.available == 0) return null;
        self.available -= 1;
        return &self.connections[self.available];
    }

    fn release(self: *ConnectionPool, conn: *Connection) void {
        conn.reset();
        self.mutex.lock() catch return;
        defer self.mutex.unlock();
        self.available += 1;
    }
};
