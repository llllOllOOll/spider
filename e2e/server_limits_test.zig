// End-to-end tests for what the server used to drop without a word: the
// middlewares past a fixed count, the response headers past another, and
// for what a static file must not answer.

const std = @import("std");
const spider = @import("spider");

const global_count = 70;
const header_count = 40;

var ran: std.atomic.Value(u32) = .init(0);

fn count(c: *spider.Ctx, next: spider.NextFn) !spider.Response {
    _ = ran.fetchAdd(1, .seq_cst);
    return next(c);
}

/// How many middlewares ran for this request.
fn counted(c: *spider.Ctx) !spider.Response {
    const n = ran.swap(0, .seq_cst);
    return c.text(try std.fmt.allocPrint(c.arena, "{d}", .{n}), .{});
}

fn manyHeaders(c: *spider.Ctx) !spider.Response {
    const headers = try c.arena.alloc([2][]const u8, header_count);
    for (headers, 0..) |*h, i| h.* = .{ try std.fmt.allocPrint(c.arena, "X-Item-{d}", .{i}), "yes" };
    const cookies = try c.arena.alloc([2][]const u8, header_count);
    for (cookies, 0..) |*k, i| k.* = .{ "c", try std.fmt.allocPrint(c.arena, "c{d}=1; Path=/", .{i}) };
    return c.text("ok", .{ .headers = headers, .cookies = cookies });
}

fn name(c: *spider.Ctx) !spider.Response {
    return c.text(c.params.get("name") orelse "", .{});
}

fn posted(c: *spider.Ctx) !spider.Response {
    return c.text("posted", .{});
}

fn run() !void {
    var server = spider.appWithConfig(.{ .views_dir = null, .static_dir = "e2e/fixtures/public" });
    defer server.deinit();
    for (0..global_count) |_| _ = server.use(count);
    try server
        .get("/counted", counted, .{ .public = true })
        .get("/many-headers", manyHeaders, .{ .public = true })
        .get("/users/:name", name, .{ .public = true })
        .post("/hello.txt", posted, .{ .public = true })
        .listen(.{});
}

test "server: every middleware given to use() runs, however many" {
    const app = try spider.testing.start(run);
    var res = try app.get("/counted");
    defer res.deinit();
    try res.expectStatus(200);
    try std.testing.expectEqualStrings("70", res.body);
}

test "server: every header and cookie of a response is sent, however many" {
    const app = try spider.testing.start(run);
    var res = try app.get("/many-headers");
    defer res.deinit();
    try res.expectStatus(200);
    try std.testing.expectEqualStrings("yes", res.header("X-Item-0").?);
    try std.testing.expectEqualStrings("yes", res.header("X-Item-39").?);
    try std.testing.expect(res.cookie("c0") != null);
    try std.testing.expect(res.cookie("c39") != null);
}

test "server: a static file answers GET and HEAD; another method goes to the routes" {
    const app = try spider.testing.start(run);

    var got = try app.get("/hello.txt");
    defer got.deinit();
    try got.expectStatus(200);
    try std.testing.expectEqualStrings("static hello\n", got.body);

    var head = try app.request(.{ .method = "HEAD", .target = "/hello.txt" });
    defer head.deinit();
    try head.expectStatus(200);
    try std.testing.expectEqualStrings("", head.body);

    // A route at the same address is the one that answers a POST.
    var post = try app.request(.{ .method = "POST", .target = "/hello.txt", .body = "x=1" });
    defer post.deinit();
    try post.expectStatus(200);
    try std.testing.expectEqualStrings("posted", post.body);

    // No route for it: not the file either.
    var delete = try app.request(.{ .method = "DELETE", .target = "/hello.txt" });
    defer delete.deinit();
    try delete.expectStatus(404);
}

test "server: a path parameter arrives decoded" {
    const app = try spider.testing.start(run);

    var spaced = try app.get("/users/Ana%20Ribeiro");
    defer spaced.deinit();
    try std.testing.expectEqualStrings("Ana Ribeiro", spaced.body);

    var accented = try app.get("/users/Jo%C3%A3o");
    defer accented.deinit();
    try std.testing.expectEqualStrings("João", accented.body);

    // An encoded slash is part of the value, not a path separator.
    var slashed = try app.get("/users/a%2Fb");
    defer slashed.deinit();
    try std.testing.expectEqualStrings("a/b", slashed.body);

    // Nothing to decode: as it is, a lone percent sign included.
    var plain = try app.get("/users/100%");
    defer plain.deinit();
    try std.testing.expectEqualStrings("100%", plain.body);
}
