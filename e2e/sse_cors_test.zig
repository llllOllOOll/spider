// End-to-end tests for which other sites may read an SSE stream: none
// unless the app lists them (Config.sse_allowed_origins).

const std = @import("std");
const spider = @import("spider");
const h = @import("../e2e_test.zig");

/// One event, then the end: the test reads the whole response.
fn once(sse: *spider.Sse) !void {
    try sse.send("hello", .{ .n = 1 });
}

const App = struct {
    port: u16 = 0,
    started: bool = false,
};

var closed: App = .{}; // the default: no other site
var listed: App = .{}; // one site listed
var open_to_all: App = .{}; // "*"
var start_mutex: std.Io.Mutex = .init;

fn runApp(port: u16, origins: []const []const u8) void {
    var s = spider.appWithConfig(.{ .views_dir = null, .static_dir = null, .sse_allowed_origins = origins });
    s.sse("/events", once)
        .listen(.{ .port = port, .host = "127.0.0.1" }) catch |err| {
        std.log.err("sse cors app listen() failed: {s}", .{@errorName(err)});
    };
}

fn ensureStarted(io: std.Io, app: *App, origins: []const []const u8) !u16 {
    try start_mutex.lock(io);
    defer start_mutex.unlock(io);
    if (!app.started) {
        app.port = try h.reserveEphemeralPort(io);
        (try std.Thread.spawn(.{}, runApp, .{ app.port, origins })).detach();
        try h.waitForPort(io, app.port);
        app.started = true;
    }
    return app.port;
}

fn stream(arena: std.mem.Allocator, port: u16, origin: ?[]const u8) !h.HttpResponse {
    var lines: [1][]const u8 = undefined;
    var n: usize = 0;
    if (origin) |o| {
        lines[0] = try std.fmt.allocPrint(arena, "Origin: {s}", .{o});
        n = 1;
    }
    const res = try h.request(std.testing.io, arena, port, "/events", .{ .headers = lines[0..n] });
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "event: hello") != null);
    return res;
}

test "sse cors: by default no other site may read a stream" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const port = try ensureStarted(std.testing.io, &closed, &.{});

    try std.testing.expect((try stream(a, port, null)).header("Access-Control-Allow-Origin") == null);
    try std.testing.expect((try stream(a, port, "https://elsewhere.example")).header("Access-Control-Allow-Origin") == null);
}

test "sse cors: a listed origin is answered by name, the others get nothing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const port = try ensureStarted(std.testing.io, &listed, &.{"https://app.example.com"});

    const allowed = try stream(a, port, "https://app.example.com");
    try std.testing.expectEqualStrings("https://app.example.com", allowed.header("Access-Control-Allow-Origin").?);
    // Caches must not hand one site's answer to another.
    try std.testing.expectEqualStrings("Origin", allowed.header("Vary").?);

    try std.testing.expect((try stream(a, port, "https://elsewhere.example")).header("Access-Control-Allow-Origin") == null);
    try std.testing.expect((try stream(a, port, "https://app.example.com.evil.example")).header("Access-Control-Allow-Origin") == null);
    try std.testing.expect((try stream(a, port, null)).header("Access-Control-Allow-Origin") == null);
}

test "sse cors: \"*\" in the list is the old behaviour, asked for" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const port = try ensureStarted(std.testing.io, &open_to_all, &.{"*"});

    try std.testing.expectEqualStrings("*", (try stream(a, port, "https://anywhere.example")).header("Access-Control-Allow-Origin").?);
}
