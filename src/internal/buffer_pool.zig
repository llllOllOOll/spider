const std = @import("std");

const SMALL_BUFFER_SIZE = 4096; // 4KB - headers
const LARGE_BUFFER_SIZE = 64 * 1024; // 64KB - bodies
const LARGE_BUFFER_COUNT = 16; // 16 slots = 1MB total

pub const BufferPool = struct {
    buffers: [][LARGE_BUFFER_SIZE]u8,
    available: []bool,
    mutex: std.Io.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !BufferPool {
        const buffers = try allocator.alloc([LARGE_BUFFER_SIZE]u8, LARGE_BUFFER_COUNT);
        const available = try allocator.alloc(bool, LARGE_BUFFER_COUNT);
        @memset(available, true);
        return .{
            .buffers = buffers,
            .available = available,
            .mutex = std.Io.Mutex.init,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BufferPool) void {
        self.allocator.free(self.buffers);
        self.allocator.free(self.available);
    }

    pub fn acquire(self: *BufferPool, io: std.Io) ?[]u8 {
        self.mutex.lock(io) catch return null;
        defer self.mutex.unlock(io);
        for (self.available, 0..) |avail, i| {
            if (avail) {
                self.available[i] = false;
                return &self.buffers[i];
            }
        }
        return null;
    }

    pub fn release(self: *BufferPool, io: std.Io, buf: []u8) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        for (self.buffers, 0..) |*b, i| {
            if (@intFromPtr(b) == @intFromPtr(buf.ptr)) {
                self.available[i] = true;
                return;
            }
        }
    }
};
