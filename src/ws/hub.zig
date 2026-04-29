const std = @import("std");
const net = std.Io.net;

pub const Hub = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    connections: std.ArrayList(Connection),

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
        defer self.mutex.unlock(self.io);

        var dead_connections: std.ArrayList(u64) = .empty;
        defer dead_connections.deinit(self.allocator);

        for (self.connections.items) |conn| {
            self.sendText(conn.stream, message) catch {
                dead_connections.append(self.allocator, conn.id) catch {};
            };
        }

        for (dead_connections.items) |id| {
            for (self.connections.items, 0..) |conn, i| {
                if (conn.id == id) {
                    _ = self.connections.orderedRemove(i);
                    break;
                }
            }
        }
    }

    fn sendText(self: *Hub, stream: net.Stream, text: []const u8) !void {
        _ = self;
        var header: [2]u8 = undefined;
        header[0] = 0x81; // text frame + fin
        header[1] = @intCast(text.len);

        var header_slice: []u8 = &header;
        while (header_slice.len > 0) {
            const written = std.os.linux.write(stream.socket.handle, header_slice.ptr, header_slice.len);
            if (written == 0) return error.BrokenPipe;
            header_slice = header_slice[written..];
        }

        var text_slice = text[0..];
        while (text_slice.len > 0) {
            const written = std.os.linux.write(stream.socket.handle, text_slice.ptr, text_slice.len);
            if (written == 0) return error.BrokenPipe;
            text_slice = text_slice[written..];
        }
    }
};
