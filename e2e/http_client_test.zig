// End-to-end tests for the address spider.http_client asks for: an app that
// answers with the target it received, so the test sees what the client
// really sent after filling in `params` and `query`.

const std = @import("std");
const spider = @import("spider");

fn echoTarget(c: *spider.Ctx) !spider.Response {
    return c.text(c.getPath(), .{});
}

fn run() !void {
    var server = spider.app(.{});
    defer server.deinit();
    try server
        .get("/items/:id", echoTarget, .{ .public = true })
        .get("/items/:id/parts/:part", echoTarget, .{ .public = true })
        .listen(.{});
}

/// GETs `path` (with `opts`) from the app and gives back the target it saw.
fn sent(arena: std.mem.Allocator, port: u16, path: []const u8, opts: spider.http_client.FetchOptions) ![]const u8 {
    const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}{s}", .{ port, path });
    var res = try spider.http_client.get(std.testing.io, arena, url, opts);
    defer res.deinit();
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    return arena.dupe(u8, res.body_text);
}

test "http client: params fill the :name placeholders" {
    const app = try spider.testing.start(run);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("/items/7", try sent(a, app.port, "/items/:id", .{ .params = &.{.{ "id", "7" }} }));
    try std.testing.expectEqualStrings("/items/7/parts/b", try sent(a, app.port, "/items/:id/parts/:part", .{
        .params = &.{ .{ "part", "b" }, .{ "id", "7" } },
    }));
}

test "http client: query adds an encoded query string" {
    const app = try spider.testing.start(run);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("/items/7?q=a%20b&n=1", try sent(a, app.port, "/items/7", .{
        .query = &.{ .{ "q", "a b" }, .{ "n", "1" } },
    }));
    try std.testing.expectEqualStrings("/items/7?x=1&q=z", try sent(a, app.port, "/items/7?x=1", .{ .query = &.{.{ "q", "z" }} }));
}

test "http client: params and query together" {
    const app = try spider.testing.start(run);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings("/items/7?q=z", try sent(arena.allocator(), app.port, "/items/:id", .{
        .params = &.{.{ "id", "7" }},
        .query = &.{.{ "q", "z" }},
    }));
}

test "http client: a param value stays one path segment" {
    const app = try spider.testing.start(run);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // A value with a slash, a space or a question mark must not change
    // which address is asked for.
    try std.testing.expectEqualStrings("/items/a%2Fb%20c%3Fd", try sent(arena.allocator(), app.port, "/items/:id", .{
        .params = &.{.{ "id", "a/b c?d" }},
    }));
}
