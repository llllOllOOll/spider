// End-to-end tests for WebSocket routes: a real client socket speaking the
// protocol by hand, so the server can be sent what a browser never would.

const std = @import("std");
const spider = @import("spider");

/// Echoes every message. "join:7" puts the connection on user 7's channel;
/// "tell:7:hello" sends "hello" to that channel.
fn chat(ws: *spider.Ws) !void {
    while (try ws.next()) |message| {
        const text = message.data;
        if (std.mem.startsWith(u8, text, "join:")) {
            try ws.joinUser(try std.fmt.parseInt(u64, text[5..], 10));
            try ws.send("joined");
        } else if (std.mem.startsWith(u8, text, "tell:")) {
            const rest = text[5..];
            const colon = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
            var buf: [32]u8 = undefined;
            const channel = try std.fmt.bufPrint(&buf, "user:{s}", .{rest[0..colon]});
            ws.broadcastTo(channel, rest[colon + 1 ..]);
        } else {
            try ws.send(text);
        }
    }
}

fn alive(c: *spider.Ctx) !spider.Response {
    return c.text("alive", .{});
}

fn run() !void {
    var server = spider.app(.{});
    defer server.deinit();
    try server
        .ws("/chat", chat)
        .get("/alive", alive, .{ .public = true })
        .listen(.{});
}

/// The browser's side of a WebSocket, by hand. Reads have a timeout, so a
/// message that never comes fails the test instead of hanging it.
const Client = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    rbuf: [1024]u8,
    seen: [2048]u8,
    len: usize,
    at: usize,

    fn open(self: *Client, io: std.Io, port: u16) !void {
        self.io = io;
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        self.stream = try address.connect(io, .{ .mode = .stream });
        errdefer self.stream.close(io);
        const tv = std.posix.timeval{ .sec = 3, .usec = 0 };
        try std.posix.setsockopt(self.stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));

        try self.write("GET /chat HTTP/1.1\r\nHost: 127.0.0.1\r\n" ++
            "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n");

        self.reader = self.stream.reader(io, &self.rbuf);
        self.len = 0;
        while (std.mem.indexOf(u8, self.seen[0..self.len], "\r\n\r\n") == null) try self.more();
        try std.testing.expect(std.mem.startsWith(u8, self.seen[0..self.len], "HTTP/1.1 101"));
        self.at = std.mem.indexOf(u8, self.seen[0..self.len], "\r\n\r\n").? + 4;
    }

    fn close(self: *Client) void {
        self.stream.close(self.io);
    }

    fn write(self: *Client, bytes: []const u8) !void {
        var wbuf: [512]u8 = undefined;
        var w = self.stream.writer(self.io, &wbuf);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
    }

    /// One masked frame, as a client must send them (short payloads only).
    fn sendFrame(self: *Client, opcode: u8, payload: []const u8) !void {
        std.debug.assert(payload.len < 126);
        var frame: [6 + 125]u8 = undefined;
        frame[0] = 0x80 | opcode;
        frame[1] = 0x80 | @as(u8, @intCast(payload.len));
        const mask = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
        frame[2..6].* = mask;
        for (payload, 0..) |byte, i| frame[6 + i] = byte ^ mask[i % 4];
        try self.write(frame[0 .. 6 + payload.len]);
    }

    fn sendText(self: *Client, text: []const u8) !void {
        try self.sendFrame(0x1, text);
    }

    fn more(self: *Client) !void {
        if (self.len == self.seen.len) return error.TestUnexpectedResult;
        var vecs: [1][]u8 = .{self.seen[self.len..]};
        const n = try self.reader.interface.readVec(&vecs);
        if (n == 0) return error.EndOfStream;
        self.len += n;
    }

    const Frame = struct { opcode: u8, payload: []const u8 };

    /// The next frame from the server (short ones only: 2-byte header).
    fn next(self: *Client) !Frame {
        while (self.len - self.at < 2) try self.more();
        const opcode = self.seen[self.at] & 0x0F;
        const size: usize = self.seen[self.at + 1];
        try std.testing.expect(size < 126);
        while (self.len - self.at < 2 + size) try self.more();
        const payload = self.seen[self.at + 2 .. self.at + 2 + size];
        self.at += 2 + size;
        return .{ .opcode = opcode, .payload = payload };
    }

    fn expectText(self: *Client, text: []const u8) !void {
        const frame = try self.next();
        try std.testing.expectEqual(@as(u8, 0x1), frame.opcode);
        try std.testing.expectEqualStrings(text, frame.payload);
    }
};

test "websocket: a text message reaches the handler and its answer comes back" {
    const app = try spider.testing.start(run);
    var client: Client = undefined;
    try client.open(std.testing.io, app.port);
    defer client.close();

    try client.sendText("hello");
    try client.expectText("hello");
}

test "websocket: a frame with a reserved opcode ends that connection, not the server" {
    const app = try spider.testing.start(run);
    var client: Client = undefined;
    try client.open(std.testing.io, app.port);
    defer client.close();

    // Opcodes 0x3 to 0x7 and 0xB to 0xF are reserved: no client should send
    // one, and anyone can.
    try client.sendFrame(0x3, "x");

    // The server says why it is closing: 1002, protocol error.
    const frame = try client.next();
    try std.testing.expectEqual(@as(u8, 0x8), frame.opcode);
    try std.testing.expectEqual(@as(u16, 1002), std.mem.readInt(u16, frame.payload[0..2], .big));

    // And it still serves everyone else.
    var res = try app.get("/alive");
    defer res.deinit();
    try res.expectStatus(200);

    var other: Client = undefined;
    try other.open(std.testing.io, app.port);
    defer other.close();
    try other.sendText("still here");
    try other.expectText("still here");
}
