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

/// Opens the dev WebSocket and returns the first text message (the boot
/// id), leaving the connection to the caller.
fn openSocket(io: std.Io, port: u16, out: *[16]u8) !std.Io.net.Stream {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = try address.connect(io, .{ .mode = .stream });
    errdefer stream.close(io);
    const tv = std.posix.timeval{ .sec = 3, .usec = 0 };
    try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));

    var wbuf: [512]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll("GET " ++ dev_reload.socket_path ++ " HTTP/1.1\r\nHost: 127.0.0.1\r\n" ++
        "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n");
    try w.interface.flush();

    var rbuf: [1024]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var seen: [1024]u8 = undefined;
    var len: usize = 0;
    // The 101 response, then one unmasked text frame: 0x81, length 16, id.
    while (true) {
        if (std.mem.indexOf(u8, seen[0..len], "\r\n\r\n")) |head_end| {
            const frame = seen[head_end + 4 .. len];
            if (frame.len >= 18) {
                try std.testing.expect(std.mem.startsWith(u8, seen[0..len], "HTTP/1.1 101"));
                try std.testing.expectEqual(@as(u8, 0x81), frame[0]);
                try std.testing.expectEqual(@as(u8, 16), frame[1]);
                out.* = frame[2..18].*;
                return stream;
            }
        }
        if (len == seen.len) return error.TestUnexpectedResult;
        var vecs: [1][]u8 = .{seen[len..]};
        const n = try reader.interface.readVec(&vecs);
        if (n == 0) return error.EndOfStream;
        len += n;
    }
}

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

    var first: [16]u8 = undefined;
    const a = try openSocket(io, port_on, &first);
    defer a.close(io);
    var second: [16]u8 = undefined;
    const b = try openSocket(io, port_on, &second);
    defer b.close(io);

    try std.testing.expectEqualStrings(&first, &second);
    try std.testing.expectEqualStrings(dev_reload.bootId(io), &first);

    // Held connections don't block ordinary requests.
    try std.testing.expectEqual(@as(u16, 200), (try e.get(port_on, "/page")).status);
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
