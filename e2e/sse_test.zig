// End-to-end tests for SSE: many simultaneous EventSource-style clients on
// one server, fan-out through the shared Hub, and normal requests staying
// responsive while SSE connections are held open.

const std = @import("std");
const spider = @import("spider");
const h = @import("../e2e_test.zig");

var port: u16 = 0;
var start_mutex: std.Io.Mutex = .init;
var started = false;

fn events(sse: *spider.Sse) !void {
    const room = sse.param("room") orelse "lobby";
    const channel = try std.fmt.allocPrint(sse.arena, "room:{s}", .{room});
    try sse.joinWithReplay(channel);
    sse.wait();
}

/// One connection, several channels — what an app does instead of opening
/// one EventSource per channel.
fn multi(sse: *spider.Sse) !void {
    try sse.subscribeWithReplay(&.{ "room:m-condo", "room:m-user", "room:m-gate" });
    sse.wait();
}

/// Sends one event, then fails: what a handler does when its query breaks.
fn failing(sse: *spider.Sse) !void {
    try sse.send("hello", .{ .n = 1 });
    return error.Boom;
}

fn emit(c: *spider.Ctx) !spider.Response {
    const room = c.params.get("room") orelse "lobby";
    const channel = try std.fmt.allocPrint(c.arena, "room:{s}", .{room});
    c.sseHub().emitTo(channel, "ping", .{ .room = room });
    return c.text("sent", .{});
}

fn count(c: *spider.Ctx) !spider.Response {
    return c.text(try std.fmt.allocPrint(c.arena, "{d}", .{c.sseHub().count()}), .{});
}

fn boom(_: *spider.Ctx) !spider.Response {
    return error.Forbidden;
}

fn hello(c: *spider.Ctx) !spider.Response {
    return c.text("hello", .{});
}

fn runApp(p: u16) void {
    var s = spider.app(.{});
    s
        // Same global middleware + hub maintenance Orbitx runs in production.
        .use(spider.logger)
        .use(spider.gzip)
        .sseHeartbeat(null)
        .sseSweep(null)
        .sse("/events/:room", events)
        .sse("/multi", multi)
        .sse("/failing", failing)
        .post("/emit/:room", emit, .{})
        .get("/sse-count", count, .{})
        .get("/hello", hello, .{})
        .get("/boom", boom, .{})
        .listen(.{ .port = p, .host = "127.0.0.1" }) catch |err| {
        std.log.err("sse app listen() failed: {s}", .{@errorName(err)});
    };
}

fn ensureStarted(io: std.Io) !void {
    try start_mutex.lock(io);
    defer start_mutex.unlock(io);
    if (started) return;
    port = try h.reserveEphemeralPort(io);
    (try std.Thread.spawn(.{}, runApp, .{port})).detach();
    try h.waitForPort(io, port);
    started = true;
}

/// One open SSE connection, read with a receive timeout so a missing event
/// fails the test instead of hanging it.
const SseClient = struct {
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    rbuf: [4096]u8,
    /// Everything read so far (test allocator; freed in close()).
    seen: std.ArrayList(u8) = .empty,

    fn open(self: *SseClient, io: std.Io, room: []const u8) !void {
        var path_buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/events/{s}", .{room});
        return self.openPath(io, path);
    }

    fn openPath(self: *SseClient, io: std.Io, path: []const u8) !void {
        self.seen = .empty;
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        self.stream = try address.connect(io, .{ .mode = .stream });
        const tv = std.posix.timeval{ .sec = 3, .usec = 0 };
        try std.posix.setsockopt(self.stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));

        var wbuf: [256]u8 = undefined;
        var w = self.stream.writer(io, &wbuf);
        try w.interface.print("GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n\r\n", .{path});
        try w.interface.flush();
        self.reader = self.stream.reader(io, &self.rbuf);
        // Status line + headers + the default "retry:" frame.
        try self.expectContains("200 OK");
        try self.expectContains("retry:");
    }

    /// Reads until `needle` shows up AFTER everything matched so far.
    fn expectContains(self: *SseClient, needle: []const u8) !void {
        const from = self.seen.items.len;
        while (std.mem.indexOf(u8, self.seen.items[from..], needle) == null) {
            const b = self.reader.interface.takeByte() catch |err| {
                std.debug.print("\n  SSE client: waiting for \"{s}\", got {s} after: {s}\n", .{ needle, @errorName(err), self.seen.items });
                return error.SseEventNotReceived;
            };
            try self.seen.append(std.testing.allocator, b);
        }
    }

    fn close(self: *SseClient, io: std.Io) void {
        self.seen.deinit(std.testing.allocator);
        self.stream.close(io);
    }
};

fn waitForCount(io: std.Io, arena: std.mem.Allocator, want: usize) !void {
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        const res = try h.request(io, arena, port, "/sse-count", .{});
        const n = try std.fmt.parseInt(usize, res.body, 10);
        if (n == want) return;
        std.Io.sleep(io, .fromMilliseconds(20), .real) catch {};
    }
    const res = try h.request(io, arena, port, "/sse-count", .{});
    std.debug.print("\n  hub count: expected {d}, got {s}\n", .{ want, res.body });
    return error.UnexpectedConnectionCount;
}

fn fanOut(n: usize, room: []const u8) !void {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try ensureStarted(io);

    const before = try std.fmt.parseInt(usize, (try h.request(io, arena.allocator(), port, "/sse-count", .{})).body, 10);

    const clients = try std.testing.allocator.alloc(SseClient, n);
    defer std.testing.allocator.free(clients);
    var opened: usize = 0;
    defer for (clients[0..opened]) |*c| c.close(io);
    for (clients) |*c| {
        try c.open(io, room);
        opened += 1;
    }
    try waitForCount(io, arena.allocator(), before + n);

    // Normal requests are still served while n SSE connections are held.
    const hello_res = try h.request(io, arena.allocator(), port, "/hello", .{});
    try std.testing.expectEqualStrings("hello", hello_res.body);

    const target = try std.fmt.allocPrint(arena.allocator(), "/emit/{s}", .{room});
    _ = try h.request(io, arena.allocator(), port, target, .{ .method = "POST", .body = "" });
    for (clients, 0..) |*c, i| {
        c.expectContains("event: ping") catch |err| {
            std.debug.print("  client {d}/{d} did not receive the event\n", .{ i + 1, n });
            return err;
        };
    }
}

test "sse: two simultaneous clients on one channel both receive an event" {
    try fanOut(2, "two");
}

test "sse: 20 simultaneous clients on one channel all receive an event" {
    try fanOut(20, "twenty");
}

test "sse: 60 simultaneous clients (30 tabs x condo+user) all receive an event" {
    try fanOut(60, "sixty");
}

test "sse: clients on different channels only get their own events" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try ensureStarted(io);

    var a: SseClient = undefined;
    var b: SseClient = undefined;
    try a.open(io, "alpha");
    defer a.close(io);
    try b.open(io, "beta");
    defer b.close(io);

    _ = try h.request(io, arena.allocator(), port, "/emit/beta", .{ .method = "POST", .body = "" });
    try b.expectContains("event: ping");
    _ = try h.request(io, arena.allocator(), port, "/emit/alpha", .{ .method = "POST", .body = "" });
    try a.expectContains("event: ping");
}

test "sse: closed clients leave the hub" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try ensureStarted(io);

    const before = try std.fmt.parseInt(usize, (try h.request(io, arena.allocator(), port, "/sse-count", .{})).body, 10);
    var c: SseClient = undefined;
    try c.open(io, "leave");
    try waitForCount(io, arena.allocator(), before + 1);
    c.close(io);
    try waitForCount(io, arena.allocator(), before);
}

fn emitNamed(io: std.Io, arena: std.mem.Allocator, room: []const u8, event_tag: []const u8) !void {
    _ = event_tag;
    const target = try std.fmt.allocPrint(arena, "/emit/{s}", .{room});
    _ = try h.request(io, arena, port, target, .{ .method = "POST", .body = "" });
}

test "sse: ONE connection subscribed to three channels receives events from all of them" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try ensureStarted(io);

    var c: SseClient = .{ .stream = undefined, .reader = undefined, .rbuf = undefined };
    try c.openPath(io, "/multi");
    defer c.close(io);

    try emitNamed(io, arena.allocator(), "not-mine", "");
    for ([_][]const u8{ "m-condo", "m-user", "m-gate" }) |room| {
        try emitNamed(io, arena.allocator(), room, "");
        var buf: [64]u8 = undefined;
        try c.expectContains(try std.fmt.bufPrint(&buf, "\"room\":\"{s}\"", .{room}));
    }
    // A channel it never subscribed to never reached it.
    try std.testing.expect(std.mem.indexOf(u8, c.seen.items, "not-mine") == null);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, c.seen.items, "event: ping"));
}

// This app has NO onError: default error mapping (statusForError).

test "default errors (no onError): status mapping, JSON for fetch callers" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try ensureStarted(io);

    const html = try h.request(io, arena.allocator(), port, "/boom", .{});
    try std.testing.expectEqual(@as(u16, 403), html.status);
    try std.testing.expectEqualStrings("Forbidden", html.body);

    const fetched = try h.request(io, arena.allocator(), port, "/boom", .{ .headers = &.{"Sec-Fetch-Dest: empty"} });
    try std.testing.expectEqual(@as(u16, 403), fetched.status);
    try std.testing.expectEqualStrings("{\"error\":\"Forbidden\",\"message\":\"Forbidden\"}", fetched.body);

    const missing = try h.request(io, arena.allocator(), port, "/nope", .{ .headers = &.{"Accept: application/json"} });
    try std.testing.expectEqual(@as(u16, 404), missing.status);
    try std.testing.expectEqualStrings("{\"error\":\"NotFound\",\"message\":\"Not Found\"}", missing.body);
}

test "sse: a handler that returns an error does not disturb the server" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try ensureStarted(io);

    var client: SseClient = .{ .stream = undefined, .reader = undefined, .rbuf = undefined };
    try client.openPath(io, "/failing");
    defer client.close(io);
    try client.expectContains("event: hello");

    // The error itself goes to the log: the response had already started.
    const res = try h.request(io, arena.allocator(), port, "/hello", .{});
    try std.testing.expectEqualStrings("hello", res.body);
}
