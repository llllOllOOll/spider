// End-to-end tests for spider.testing.start: an app's own tests send real
// requests to its server (forms, cookies, redirects, the error handler).

const std = @import("std");
const spider = @import("spider");

const Note = struct { title: []const u8 = "", author: []const u8 = "" };

fn show(c: *spider.Ctx) !spider.Response {
    const id = c.params.get("id") orelse return error.NotFound;
    if (std.mem.eql(u8, id, "missing")) return error.NotFound;
    const who = c.cookieDecoded("author") orelse "nobody";
    return c.html(try std.fmt.allocPrint(c.arena, "<h1>note {s}</h1><p>by {s}</p>", .{ id, who }), .{});
}

fn create(c: *spider.Ctx) !spider.Response {
    const note = try c.parseForm(Note);
    if (note.title.len == 0) return c.text("Give the note a title.", .{ .status = .unprocessable_entity });
    return c.redirectWith("/notes/1", try c.withCookie("author", note.author, .{ .encode = true }));
}

fn echoJson(c: *spider.Ctx) !spider.Response {
    const note = try c.bodyJson(Note);
    return c.json(.{ .title = note.title }, .{});
}

fn onError(c: *spider.Ctx, err: anyerror) anyerror!spider.Response {
    if (err == error.NotFound) return c.text("no such note", .{ .status = .not_found });
    return err;
}

fn run() !void {
    var server = spider.app(.{});
    defer server.deinit();
    // The port and host asked for here are replaced by the test's own.
    try server
        .get("/notes/:id", show, .{ .public = true })
        .post("/notes", create, .{ .public = true })
        .post("/echo", echoJson, .{ .public = true })
        .onError(onError)
        .listen(.{ .port = 3000, .host = "0.0.0.0" });
}

test "testing.start: GET, with the route's params and the error handler" {
    const app = try spider.testing.start(run);
    try std.testing.expect(app.port != 3000);

    var res = try app.get("/notes/7");
    defer res.deinit();
    try res.expectStatus(200);
    try res.expectContains("<h1>note 7</h1>");
    try res.expectContains("by nobody");
    try res.expectNotContains("error");

    var missing = try app.get("/notes/missing");
    defer missing.deinit();
    try missing.expectStatus(404);
    try missing.expectContains("no such note");
}

test "testing.start: a form, the redirect it answers and the cookie it sets" {
    const app = try spider.testing.start(run);

    var res = try app.postForm("/notes", .{ .title = "Hello", .author = "Zé; da Silva" });
    defer res.deinit();
    try res.expectRedirect("/notes/1");
    try res.expectStatus(303);
    const author = res.cookie("author").?;
    try std.testing.expectEqualStrings("Z%C3%A9%3B%20da%20Silva", author);

    var buf: [128]u8 = undefined;
    const cookie = try std.fmt.bufPrint(&buf, "Cookie: author={s}", .{author});
    var page = try app.request(.{ .target = "/notes/1", .headers = &.{cookie} });
    defer page.deinit();
    try page.expectContains("by Zé; da Silva");

    var invalid = try app.postForm("/notes", .{ .title = "", .author = "x" });
    defer invalid.deinit();
    try invalid.expectStatus(422);
    try invalid.expectContains("Give the note a title.");
}

test "testing.start: JSON in and out, and the same server for every test" {
    const app = try spider.testing.start(run);
    const again = try spider.testing.start(run);
    try std.testing.expectEqual(app.port, again.port);

    var res = try app.postJson("/echo", "{\"title\":\"From JSON\"}");
    defer res.deinit();
    try res.expectStatus(200);
    try res.expectHeader("Content-Type", "application/json");
    try res.expectContains("From JSON");
}
