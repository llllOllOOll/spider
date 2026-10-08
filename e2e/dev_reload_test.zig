// End-to-end tests for the `spider dev` browser reload: the script tag in
// HTML pages, the script and the WebSocket served before any middleware,
// and nothing at all when it is off.

const std = @import("std");
const spider = @import("spider");
const h = @import("../e2e_test.zig");
const dev_reload = spider.dev_reload;

const page_html = "<!doctype html><html><body><h1>page</h1></body></html>";
const fragment_html = "<div id=\"rows\"><p>row</p></div>";

fn page(c: *spider.Ctx) !spider.Response {
    return c.html(page_html, .{});
}

fn fragment(c: *spider.Ctx) !spider.Response {
    return c.html(fragment_html, .{});
}

fn data(c: *spider.Ctx) !spider.Response {
    return c.json(.{ .note = "</body>" }, .{});
}

/// What an app's auth does to a path it does not know: refuse it.
fn denySpiderPaths(c: *spider.Ctx, next: spider.NextFn) anyerror!spider.Response {
    if (std.mem.startsWith(u8, c.getPath(), "/_spider/")) return error.Unauthorized;
    return next(c);
}

fn runApp(port: u16, on: bool) void {
    var s = spider.appWithConfig(.{ .views_dir = null, .static_dir = null, .dev_reload = on });
    s
        .use(denySpiderPaths)
        .get("/page", page, .{})
        .get("/fragment", fragment, .{})
        .get("/data", data, .{})
        .listen(.{ .port = port, .host = "127.0.0.1" }) catch |err| {
        std.log.warn("dev reload app listen() failed: {s}", .{@errorName(err)});
    };
}

var port_on: u16 = 0;
var port_off: u16 = 0;
var start_mutex: std.Io.Mutex = .init;
var started = false;

fn ensureStarted(io: std.Io) !void {
    try start_mutex.lock(io);
    defer start_mutex.unlock(io);
    if (started) return;
    port_on = try h.reserveEphemeralPort(io);
    (try std.Thread.spawn(.{}, runApp, .{ port_on, true })).detach();
    try h.waitForPort(io, port_on);
    port_off = try h.reserveEphemeralPort(io);
    (try std.Thread.spawn(.{}, runApp, .{ port_off, false })).detach();
    try h.waitForPort(io, port_off);
    started = true;
}

const Env = struct {
    arena: std.heap.ArenaAllocator,

    fn init() !Env {
        try ensureStarted(std.testing.io);
        return .{ .arena = .init(std.testing.allocator) };
    }
    fn deinit(self: *Env) void {
        self.arena.deinit();
    }
    fn get(self: *Env, port: u16, target: []const u8) !h.HttpResponse {
        return h.request(std.testing.io, self.arena.allocator(), port, target, .{});
    }
};

/// The dev WebSocket from the browser's side: unmasked text frames from
/// the server, read with a receive timeout so a missing message fails the
/// test instead of hanging it.
const Socket = struct {
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    rbuf: [1024]u8,
    seen: [2048]u8,
    len: usize,
    /// Where the next unread frame starts in `seen`.
    at: usize,

    fn open(self: *Socket, io: std.Io, port: u16) !void {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        self.stream = try address.connect(io, .{ .mode = .stream });
        errdefer self.stream.close(io);
        const tv = std.posix.timeval{ .sec = 3, .usec = 0 };
        try std.posix.setsockopt(self.stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));

        var wbuf: [512]u8 = undefined;
        var w = self.stream.writer(io, &wbuf);
        try w.interface.writeAll("GET " ++ dev_reload.socket_path ++ " HTTP/1.1\r\nHost: 127.0.0.1\r\n" ++
            "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n");
        try w.interface.flush();

        self.reader = self.stream.reader(io, &self.rbuf);
        self.len = 0;
        while (std.mem.indexOf(u8, self.seen[0..self.len], "\r\n\r\n") == null) try self.more();
        try std.testing.expect(std.mem.startsWith(u8, self.seen[0..self.len], "HTTP/1.1 101"));
        self.at = std.mem.indexOf(u8, self.seen[0..self.len], "\r\n\r\n").? + 4;
    }

    fn more(self: *Socket) !void {
        if (self.len == self.seen.len) return error.TestUnexpectedResult;
        var vecs: [1][]u8 = .{self.seen[self.len..]};
        const n = try self.reader.interface.readVec(&vecs);
        if (n == 0) return error.EndOfStream;
        self.len += n;
    }

    /// The next text message (short ones only: 2-byte frame header).
    fn next(self: *Socket) ![]const u8 {
        while (self.len - self.at < 2) try self.more();
        try std.testing.expectEqual(@as(u8, 0x81), self.seen[self.at]);
        const size: usize = self.seen[self.at + 1];
        try std.testing.expect(size < 126);
        while (self.len - self.at < 2 + size) try self.more();
        const text = self.seen[self.at + 2 .. self.at + 2 + size];
        self.at += 2 + size;
        return text;
    }

    /// The next message that is not the keep-alive.
    fn nextEvent(self: *Socket) ![]const u8 {
        while (true) {
            const text = try self.next();
            if (!std.mem.eql(u8, text, "ping")) return text;
        }
    }

    fn close(self: *Socket, io: std.Io) void {
        self.stream.close(io);
    }
};

test "dev reload: an HTML page gets the script tag before </body>" {
    if (!dev_reload.compiled_in) return error.SkipZigTest;
    var e = try Env.init();
    defer e.deinit();
    const res = try e.get(port_on, "/page");
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings(
        "<!doctype html><html><body><h1>page</h1>" ++ dev_reload.script_tag ++ "</body></html>",
        res.body,
    );
}

test "dev reload: fragments and non-HTML responses are left alone" {
    if (!dev_reload.compiled_in) return error.SkipZigTest;
    var e = try Env.init();
    defer e.deinit();
    try std.testing.expectEqualStrings(fragment_html, (try e.get(port_on, "/fragment")).body);
    const json = try e.get(port_on, "/data");
    try std.testing.expect(std.mem.indexOf(u8, json.body, dev_reload.script_path) == null);
}

test "dev reload: the script is served past a middleware that refuses the path" {
    if (!dev_reload.compiled_in) return error.SkipZigTest;
    var e = try Env.init();
    defer e.deinit();
    const res = try e.get(port_on, dev_reload.script_path);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings(dev_reload.script, res.body);
    try std.testing.expect(std.mem.startsWith(u8, res.header("content-type").?, "text/javascript"));
    try std.testing.expectEqualStrings("no-store", res.header("cache-control").?);
}

test "dev reload: the socket sends this process's boot id, the same to everyone" {
    if (!dev_reload.compiled_in) return error.SkipZigTest;
    var e = try Env.init();
    defer e.deinit();
    const io = std.testing.io;

    var a: Socket = undefined;
    try a.open(io, port_on);
    defer a.close(io);
    var b: Socket = undefined;
    try b.open(io, port_on);
    defer b.close(io);

    const expected = try std.fmt.allocPrint(e.arena.allocator(), "id:{s}", .{dev_reload.bootId(io)});
    try std.testing.expectEqualStrings(expected, try a.next());
    try std.testing.expectEqualStrings(expected, try b.next());

    // Held connections don't block ordinary requests.
    try std.testing.expectEqual(@as(u16, 200), (try e.get(port_on, "/page")).status);
}

test "dev reload: a change in the reload file reaches every open socket as 'reload'" {
    if (!dev_reload.compiled_in) return error.SkipZigTest;
    var e = try Env.init();
    defer e.deinit();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const path = try std.fs.path.join(e.arena.allocator(), &.{ dir_path, "reload" });
    dev_reload.setReloadFile(path);
    defer dev_reload.setReloadFile(null);

    var a: Socket = undefined;
    try a.open(io, port_on);
    defer a.close(io);
    var b: Socket = undefined;
    try b.open(io, port_on);
    defer b.close(io);
    _ = try a.next();
    _ = try b.next();

    // What `spider dev` does when only the stylesheet changed.
    {
        const file = try tmp.dir.createFile(io, "reload", .{});
        defer file.close(io);
        var buf: [16]u8 = undefined;
        var w: std.Io.File.Writer = .init(file, io, &buf);
        try w.interface.writeAll("1\n");
        try w.interface.flush();
    }
    try std.testing.expectEqualStrings("reload", try a.nextEvent());
    try std.testing.expectEqualStrings("reload", try b.nextEvent());
}

test "dev reload: a plain GET on the socket path is a 400, not a hang" {
    if (!dev_reload.compiled_in) return error.SkipZigTest;
    var e = try Env.init();
    defer e.deinit();
    try std.testing.expectEqual(@as(u16, 400), (try e.get(port_on, dev_reload.socket_path)).status);
}

test "dev reload off: no tag, and the paths belong to the app again" {
    var e = try Env.init();
    defer e.deinit();
    try std.testing.expectEqualStrings(page_html, (try e.get(port_off, "/page")).body);
    // The app's middleware refuses /_spider/*: nothing answered before it.
    try std.testing.expectEqual(@as(u16, 401), (try e.get(port_off, dev_reload.script_path)).status);
    try std.testing.expectEqual(@as(u16, 401), (try e.get(port_off, dev_reload.socket_path)).status);
}
