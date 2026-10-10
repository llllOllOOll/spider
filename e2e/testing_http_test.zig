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

const Order = struct { quantity: i32, code: [2]u8 = .{ 0, 0 }, note: []const u8 = "" };

fn order(c: *spider.Ctx) !spider.Response {
    const sent = try c.bodyJson(Order);
    return c.json(.{ .quantity = sent.quantity }, .{});
}

fn onError(c: *spider.Ctx, err: anyerror) anyerror!spider.Response {
    if (err == error.NotFound) return c.text("no such note", .{ .status = .not_found });
    // Everything else: the status Spider gives the error by default.
    return c.text(@errorName(err), .{ .status = spider.statusForError(err) });
}

fn run() !void {
    var server = spider.app(.{});
    defer server.deinit();
    // The port and host asked for here are replaced by the test's own.
    try server
        .get("/notes/:id", show, .{ .public = true })
        .post("/notes", create, .{ .public = true })
        .post("/echo", echoJson, .{ .public = true })
        .post("/order", order, .{ .public = true })
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

test "bodyJson: JSON that does not fit the type is the client's mistake, a 400" {
    const app = try spider.testing.start(run);

    var good = try app.postJson("/order", "{\"quantity\": 3}");
    defer good.deinit();
    try good.expectStatus(200);

    // Each of these used to answer 500, as if the server had failed.
    const bad = [_][]const u8{
        "{\"quantity\": 99999999999}", // too big for the field
        "{\"quantity\": \"12a\"}", // a number written as text, badly
        "{\"quantity\": 1, \"code\": [1, 2, 3]}", // three values for two places
    };
    for (bad) |body| {
        var res = try app.request(.{ .method = "POST", .target = "/order", .headers = &.{"Content-Type: application/json"}, .body = body });
        defer res.deinit();
        res.expectStatus(400) catch |err| {
            std.debug.print("\n  body: {s}\n", .{body});
            return err;
        };
    }

    // What already was a 400 still is.
    var broken = try app.request(.{ .method = "POST", .target = "/order", .headers = &.{"Content-Type: application/json"}, .body = "{\"quantity\": " });
    defer broken.deinit();
    try broken.expectStatus(400);
    var missing = try app.request(.{ .method = "POST", .target = "/order", .headers = &.{"Content-Type: application/json"}, .body = "{}" });
    defer missing.deinit();
    try missing.expectStatus(400);
}
