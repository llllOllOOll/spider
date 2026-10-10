// End-to-end tests for WebSocket routes: a real client socket speaking the
// protocol by hand, so the server can be sent what a browser never would.

const std = @import("std");
const spider = @import("spider");

/// Echoes every message. "join:7" puts the connection on user 7's channel;
/// "tell:7:hello" sends "hello" to that channel. "flood" sends this
/// connection many messages of 'a'; "shout" broadcasts as many of 'b' to
/// everyone.
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
        } else if (std.mem.eql(u8, text, "fail")) {
            // What a handler does when its own work breaks mid-conversation.
            return error.Boom;
        } else if (std.mem.eql(u8, text, "flood")) {
            const mine: [flood_size]u8 = @splat('a');
            for (0..flood_count) |_| try ws.send(&mine);
        } else if (std.mem.eql(u8, text, "shout")) {
            const everyone: [flood_size]u8 = @splat('b');
            for (0..flood_count) |_| ws.broadcast(&everyone);
        } else {
            try ws.send(text);
        }
    }
}

const flood_count = 3000;
const flood_size = 100;

fn alive(c: *spider.Ctx) !spider.Response {
    return c.text("alive", .{});
}

fn run() !void {
    var server = spider.app(.{});
    defer server.deinit();
    try server
        .ws("/chat", chat)
        .wsWith("/members", chat, .{ .authenticated = true })
        .wsWith("/open", chat, .{ .public = true })
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
        try self.request(io, port, "/chat");
        try std.testing.expect(std.mem.startsWith(u8, self.seen[0..self.len], "HTTP/1.1 101"));
    }

    /// Asks for a WebSocket at `path` and reads the answer's head; what it
    /// says is the caller's to check.
    fn request(self: *Client, io: std.Io, port: u16, comptime path: []const u8) !void {
        self.io = io;
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        self.stream = try address.connect(io, .{ .mode = .stream });
        errdefer self.stream.close(io);
        const tv = std.posix.timeval{ .sec = 3, .usec = 0 };
        try std.posix.setsockopt(self.stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));

        try self.write("GET " ++ path ++ " HTTP/1.1\r\nHost: 127.0.0.1\r\n" ++
            "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n");

        self.reader = self.stream.reader(io, &self.rbuf);
        self.len = 0;
        while (std.mem.indexOf(u8, self.seen[0..self.len], "\r\n\r\n") == null) try self.more();
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
        if (self.len == self.seen.len) {
            // Full: drop what was already read. (Payloads handed out
            // before this point are gone; look at each one right away.)
            if (self.at == 0) return error.TestUnexpectedResult;
            std.mem.copyForwards(u8, self.seen[0 .. self.len - self.at], self.seen[self.at..self.len]);
            self.len -= self.at;
            self.at = 0;
        }
        // Whatever the reader has, at least one byte: it waits on the
        // socket only when it holds nothing.
        const got = try self.reader.interface.peekGreedy(1);
        const n = @min(got.len, self.seen.len - self.len);
        @memcpy(self.seen[self.len..][0..n], got[0..n]);
        self.reader.interface.toss(n);
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

test "websocket: joinUser puts the connection on the user's channel, and it stays there" {
    const app = try spider.testing.start(run);
    var ana: Client = undefined;
    try ana.open(std.testing.io, app.port);
    defer ana.close();
    var other: Client = undefined;
    try other.open(std.testing.io, app.port);
    defer other.close();

    try ana.sendText("join:7");
    try ana.expectText("joined");

    // Some traffic in between: the channel name must not live in memory
    // the handler's next calls reuse.
    try ana.sendText("one");
    try ana.expectText("one");
    try ana.sendText("two");
    try ana.expectText("two");

    try other.sendText("tell:7:for you");
    try ana.expectText("for you");

    // Nobody else is on that channel.
    try other.sendText("tell:8:not for ana");
    try other.sendText("ping me");
    try other.expectText("ping me");
    try ana.sendText("three");
    try ana.expectText("three");
}

/// Reads `count` frames and throws them away.
fn drain(client: *Client, count: usize) void {
    for (0..count) |_| _ = client.next() catch return;
}

test "websocket: a handler's own send and a broadcast from another connection never mix their bytes" {
    const app = try spider.testing.start(run);
    var ana: Client = undefined;
    try ana.open(std.testing.io, app.port);
    defer ana.close();
    var other: Client = undefined;
    try other.open(std.testing.io, app.port);
    defer other.close();

    // Both start writing to ana's socket at once: her handler with send(),
    // the other connection's handler with broadcast().
    try ana.sendText("flood");
    try other.sendText("shout");

    // The broadcast goes to the other connection too. Someone has to read
    // it there, or its socket fills up and the server waits on it.
    const reader = try std.Thread.spawn(.{}, drain, .{ &other, flood_count });
    defer reader.join();

    var from_send: usize = 0;
    var from_broadcast: usize = 0;
    while (from_send < flood_count or from_broadcast < flood_count) {
        const frame = try ana.next();
        // Every frame is whole: a text frame of one letter, start to end.
        try std.testing.expectEqual(@as(u8, 0x1), frame.opcode);
        try std.testing.expectEqual(@as(usize, flood_size), frame.payload.len);
        const letter = frame.payload[0];
        try std.testing.expect(letter == 'a' or letter == 'b');
        for (frame.payload) |byte| try std.testing.expectEqual(letter, byte);
        if (letter == 'a') from_send += 1 else from_broadcast += 1;
    }
    try std.testing.expectEqual(@as(usize, flood_count), from_send);
    try std.testing.expectEqual(@as(usize, flood_count), from_broadcast);
}

test "websocket: wsWith says who may open the socket" {
    const app = try spider.testing.start(run);

    // Nobody signed in: refused before the protocol is switched.
    var anonymous: Client = undefined;
    try anonymous.request(std.testing.io, app.port, "/members");
    defer anonymous.close();
    try std.testing.expect(std.mem.startsWith(u8, anonymous.seen[0..anonymous.len], "HTTP/1.1 401"));

    // A public one opens and works like any other.
    var visitor: Client = undefined;
    try visitor.request(std.testing.io, app.port, "/open");
    defer visitor.close();
    try std.testing.expect(std.mem.startsWith(u8, visitor.seen[0..visitor.len], "HTTP/1.1 101"));
    try visitor.sendText("hello");
    try visitor.expectText("hello");
}

test "websocket: a handler that returns an error closes the socket; no HTTP answer is written into it" {
    const app = try spider.testing.start(run);
    var client: Client = undefined;
    try client.open(std.testing.io, app.port);
    defer client.close();

    try client.sendText("fail");

    // The server says the socket is closing and why (1011: it met
    // something unexpected), in the protocol's own terms: never the text
    // of an HTTP response, which a browser would read as a broken frame.
    const frame = try client.next();
    try std.testing.expectEqual(@as(u8, 0x8), frame.opcode);
    try std.testing.expectEqual(@as(u16, 1011), std.mem.readInt(u16, frame.payload[0..2], .big));
    // And then it does close.
    try std.testing.expectError(error.EndOfStream, client.more());

    // The server goes on.
    var res = try app.get("/alive");
    defer res.deinit();
    try res.expectStatus(200);
}
