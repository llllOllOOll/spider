const std = @import("std");
const net = std.Io.net;

pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    masked: bool,
    payload: []const u8,

    pub const Opcode = enum(u4) {
        continuation = 0x0,
        text = 0x1,
        binary = 0x2,
        close = 0x8,
        ping = 0x9,
        pong = 0xA,
    };
};

pub const Server = struct {
    stream: net.Stream,
    io: std.Io,
    allocator: std.mem.Allocator,
    _read_buf: [65536]u8 = undefined,
    _write_buf: [4096]u8 = undefined,

    pub fn init(stream: net.Stream, io: std.Io, allocator: std.mem.Allocator) Server {
        return .{
            .stream = stream,
            .io = io,
            .allocator = allocator,
        };
    }

    fn readAll(self: *Server, buf: []u8) !void {
        var sr = net.Stream.Reader.init(self.stream, self.io, &self._read_buf);
        try sr.interface.readSliceAll(buf);
    }

    fn writeAll(self: *Server, data: []const u8) !void {
        var sw = net.Stream.Writer.init(self.stream, self.io, &self._write_buf);
        try sw.interface.writeAll(data);
        try sw.interface.flush();
    }

    pub fn handshake(self: *Server, allocator: std.mem.Allocator, headers: *const std.StringHashMapUnmanaged([]const u8)) !bool {
        const upgrade = headers.get("Upgrade") orelse headers.get("upgrade") orelse return false;
        if (!std.ascii.eqlIgnoreCase(upgrade, "websocket")) return false;

        const key = headers.get("Sec-WebSocket-Key") orelse headers.get("sec-websocket-key") orelse return false;

        var accept_buf: [32]u8 = undefined;
        const accept = generateAccept(key, &accept_buf);

        const response = try std.fmt.allocPrint(
            allocator,
            "HTTP/1.1 101 Switching Protocols\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Accept: {s}\r\n" ++
                "\r\n",
            .{accept},
        );
        defer allocator.free(response);

        try self.writeAll(response);
        return true;
    }

    fn generateAccept(key: []const u8, out: *[32]u8) []const u8 {
        const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(key);
        sha1.update(magic);
        var digest: [20]u8 = undefined;
        sha1.final(&digest);

        const encoded = std.base64.standard.Encoder.encode(out, &digest);
        return encoded[0..];
    }

    pub fn readFrame(self: *Server, arena: std.mem.Allocator) !?Frame {
        var header: [2]u8 = undefined;
        self.readAll(&header) catch |err| {
            if (err == error.EndOfStream) return null;
            return err;
        };

        const first_byte = header[0];
        const fin = (first_byte & 0x80) != 0;
        const opcode_val: u4 = @intCast(first_byte & 0x0F);
        const opcode: Frame.Opcode = @enumFromInt(opcode_val);
        const masked = (header[1] & 0x80) != 0;
        var payload_len: u64 = @intCast(header[1] & 0x7F);

        if (payload_len == 126) {
            var len_buf: [2]u8 = undefined;
            try self.readAll(&len_buf);
            payload_len = std.mem.readInt(u16, &len_buf, .big);
        } else if (payload_len == 127) {
            var len_buf: [8]u8 = undefined;
            try self.readAll(&len_buf);
            payload_len = std.mem.readInt(u64, &len_buf, .big);
        }

        var mask_key: [4]u8 = undefined;
        if (masked) {
            try self.readAll(&mask_key);
        }

        if (payload_len > 16 * 1024 * 1024) {
            var code_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &code_buf, 1009, .big);
            self.writeFrame(.close, &code_buf) catch {};
            return error.MessageTooBig;
        }

        var payload: []u8 = undefined;
        if (payload_len > 0) {
            payload = try arena.alloc(u8, @intCast(payload_len));
            try self.readAll(payload);
        } else {
            payload = &.{};
        }

        if (masked) {
            for (payload, 0..) |*b, i| {
                b.* ^= mask_key[i % 4];
            }
        }

        const frame = Frame{
            .fin = fin,
            .opcode = opcode,
            .masked = masked,
            .payload = payload,
        };

        if (frame.opcode == .ping) {
            try self.writeFrame(.pong, frame.payload);
            return self.readFrame(arena);
        }

        if (frame.opcode == .close) {
            try self.writeFrame(.close, frame.payload);
            return null;
        }

        return frame;
    }

    pub fn writeFrame(self: *Server, opcode: Frame.Opcode, payload: []const u8) !void {
        var header: [10]u8 = undefined;
        var header_len: usize = 2;
        header[0] = 0x80 | @as(u8, @intFromEnum(opcode));

        if (payload.len < 126) {
            header[1] = @intCast(payload.len);
        } else if (payload.len < 65536) {
            header[1] = 126;
            std.mem.writeInt(u16, header[2..4], @as(u16, @intCast(payload.len)), .big);
            header_len = 4;
        } else {
            header[1] = 127;
            std.mem.writeInt(u64, header[2..10], payload.len, .big);
            header_len = 10;
        }

        try self.writeAll(header[0..header_len]);

        if (payload.len > 0) {
            try self.writeAll(payload);
        }
    }

    pub fn sendText(self: *Server, text: []const u8) !void {
        try self.writeFrame(.text, text);
    }

    pub fn sendClose(self: *Server, code: u16) !void {
        var close_frame: [2]u8 = undefined;
        std.mem.writeInt(u16, &close_frame, code, .big);
        try self.writeFrame(.close, &close_frame);
    }

    pub fn sendPong(self: *Server, payload: []const u8) !void {
        try self.writeFrame(.pong, payload);
    }
};
