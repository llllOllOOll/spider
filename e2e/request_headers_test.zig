// End-to-end tests for request headers that come more than once: a client,
// or a proxy on the way, may send the same header on several lines.

const std = @import("std");
const spider = @import("spider");
const h = @import("../e2e_test.zig");

fn echo(c: *spider.Ctx) !spider.Response {
    return c.text(try std.fmt.allocPrint(c.arena, "trace={s}|a={s}|b={s}|ip={s}", .{
        c.header("X-Trace") orelse "-",
        c.cookie("a") orelse "-",
        c.cookie("b") orelse "-",
        c.clientIp() orelse "-",
    }), .{});
}

var port: u16 = 0;
var started = false;
var start_mutex: std.Io.Mutex = .init;

fn runApp(p: u16) void {
    // The test's own machine is the "proxy" whose X-Forwarded-For is believed.
    var s = spider.appWithConfig(.{ .views_dir = null, .static_dir = null, .trusted_proxies = &.{"127.0.0.1"} });
    s.get("/echo", echo, .{ .public = true })
        .listen(.{ .port = p, .host = "127.0.0.1" }) catch |err| {
        std.log.err("request headers app listen() failed: {s}", .{@errorName(err)});
    };
}

fn ask(arena: std.mem.Allocator, headers: []const []const u8) ![]const u8 {
    const io = std.testing.io;
    try start_mutex.lock(io);
    if (!started) {
        port = try h.reserveEphemeralPort(io);
        (try std.Thread.spawn(.{}, runApp, .{port})).detach();
        try h.waitForPort(io, port);
        started = true;
    }
    start_mutex.unlock(io);
    const res = try h.request(io, arena, port, "/echo", .{ .headers = headers });
    try std.testing.expectEqual(@as(u16, 200), res.status);
    return res.body;
}

test "request headers: a header sent on two lines keeps both values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const body = try ask(arena.allocator(), &.{ "X-Trace: first", "X-Trace: second" });
    // One value, joined with a comma, as HTTP says a list may be folded.
    try std.testing.expect(std.mem.startsWith(u8, body, "trace=first, second|"));
}

test "request headers: cookies sent on two Cookie lines are all read" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const body = try ask(arena.allocator(), &.{ "Cookie: a=1", "Cookie: b=2" });
    try std.testing.expect(std.mem.indexOf(u8, body, "|a=1|b=2|") != null);
}

test "request headers: the same header in another letter case is the same header" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const body = try ask(arena.allocator(), &.{ "x-trace: lower", "X-TRACE: upper" });
    try std.testing.expect(std.mem.startsWith(u8, body, "trace=lower, upper|"));
}

test "request headers: X-Forwarded-For on two lines is one chain, read right to left" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // The client's own claim first, the address a proxy saw second: the
    // last one is what the trusted proxy vouches for.
    const body = try ask(arena.allocator(), &.{ "X-Forwarded-For: 10.9.9.9", "X-Forwarded-For: 203.0.113.7" });
    try std.testing.expect(std.mem.endsWith(u8, body, "|ip=203.0.113.7"));
}
