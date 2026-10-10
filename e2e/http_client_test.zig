// End-to-end tests for the address spider.http_client asks for: an app that
// answers with the target it received, so the test sees what the client
// really sent after filling in `params` and `query`.

const std = @import("std");
const spider = @import("spider");

fn echoTarget(c: *spider.Ctx) !spider.Response {
    return c.text(c.getPath(), .{});
}

fn echoHeaders(c: *spider.Ctx) !spider.Response {
    return c.text(try std.fmt.allocPrint(c.arena, "{s}|{s}", .{ c.header("X-Key") orelse "-", c.header("X-Trace") orelse "-" }), .{});
}

fn run() !void {
    var server = spider.app(.{});
    defer server.deinit();
    try server
        .get("/items/:id", echoTarget, .{ .public = true })
        .get("/items/:id/parts/:part", echoTarget, .{ .public = true })
        .get("/headers", echoHeaders, .{ .public = true })
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

test "http client: a Client sends its own headers and the ones of each request" {
    const app = try spider.testing.start(run);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var client = try spider.http_client.Client.init(std.testing.io, a, .{
        .base_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{app.port}),
        .headers = &.{.{ .name = "X-Key", .value = "client-key" }},
    });
    defer client.deinit();

    // The client's alone.
    var plain = try client.get("/headers", .{});
    defer plain.deinit();
    try std.testing.expectEqualStrings("client-key|-", plain.body_text);

    // Plus one given for this request.
    var traced = try client.get("/headers", .{ .headers = &.{.{ .name = "X-Trace", .value = "t-1" }} });
    defer traced.deinit();
    try std.testing.expectEqualStrings("client-key|t-1", traced.body_text);

    // A request's header replaces the client's of the same name, for that request.
    var replaced = try client.get("/headers", .{ .headers = &.{.{ .name = "x-key", .value = "other-key" }} });
    defer replaced.deinit();
    try std.testing.expectEqualStrings("other-key|-", replaced.body_text);

    var after = try client.get("/headers", .{});
    defer after.deinit();
    try std.testing.expectEqualStrings("client-key|-", after.body_text);
}

test "http client: a body with GET, HEAD or DELETE is an error, not a crash" {
    const app = try spider.testing.start(run);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/items/7", .{app.port});

    try std.testing.expectError(error.BodyNotAllowed, spider.http_client.get(std.testing.io, a, url, .{ .body = .{ .raw = "x" } }));
    try std.testing.expectError(error.BodyNotAllowed, spider.http_client.delete(std.testing.io, a, url, .{ .body = .{ .raw = "x" } }));
    try std.testing.expectError(error.BodyNotAllowed, spider.http_client.head(std.testing.io, a, url, .{ .body = .{ .raw = "x" } }));

    // Without one they go as before.
    var res = try spider.http_client.get(std.testing.io, a, url, .{});
    defer res.deinit();
    try std.testing.expectEqualStrings("/items/7", res.body_text);
}
