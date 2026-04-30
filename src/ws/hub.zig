const std = @import("std");
const net = std.Io.net;

pub const Hub = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    connections: std.ArrayListUnmanaged(Connection) = .empty,

    pub const Connection = struct {
        id: u64,
        stream: net.Stream,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Hub {
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = std.Io.Mutex.init,
            .connections = .empty,
        };
    }

    pub fn deinit(self: *Hub) void {
        self.connections.deinit(self.allocator);
    }

    pub fn add(self: *Hub, conn: Connection) !void {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);
        try self.connections.append(self.allocator, conn);
    }

    pub fn remove(self: *Hub, conn_id: u64) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        for (self.connections.items, 0..) |conn, i| {
            if (conn.id == conn_id) {
                _ = self.connections.orderedRemove(i);
                return;
            }
        }
    }

    pub fn count(self: *Hub) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        return self.connections.items.len;
    }

    pub fn broadcast(self: *Hub, message: []const u8) void {
        self.mutex.lock(self.io) catch return;
        var snapshot: std.ArrayListUnmanaged(Connection) = .empty;
        defer snapshot.deinit(self.allocator);
        for (self.connections.items) |conn| {
            snapshot.append(self.allocator, conn) catch {};
        }
        self.mutex.unlock(self.io);

        var dead: std.ArrayListUnmanaged(u64) = .empty;
        defer dead.deinit(self.allocator);

        for (snapshot.items) |conn| {
            self.sendText(conn.stream, message) catch {
                dead.append(self.allocator, conn.id) catch {};
            };
        }

        if (dead.items.len == 0) return;
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        for (dead.items) |id| {
            for (self.connections.items, 0..) |conn, i| {
                if (conn.id == id) {
                    _ = self.connections.orderedRemove(i);
                    break;
                }
            }
        }
    }

    fn sendText(self: *Hub, stream: net.Stream, text: []const u8) !void {
        var write_buf: [4096]u8 = undefined;
        var sw = net.Stream.Writer.init(stream, self.io, &write_buf);
        const writer = &sw.interface;

        var header_buf: [10]u8 = undefined;
        var header_len: usize = 2;
        header_buf[0] = 0x81;

        if (text.len < 126) {
            header_buf[1] = @intCast(text.len);
        } else if (text.len < 65536) {
            header_buf[1] = 126;
            std.mem.writeInt(u16, header_buf[2..4], @intCast(text.len), .big);
            header_len = 4;
        } else {
            header_buf[1] = 127;
            std.mem.writeInt(u64, header_buf[2..10], text.len, .big);
            header_len = 10;
        }

        try writer.writeAll(header_buf[0..header_len]);
        try writer.writeAll(text);
        try writer.flush();
    }
};
