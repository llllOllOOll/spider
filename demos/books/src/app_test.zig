//! Requests against the app itself, in `zig build test`.
//!
//! `spider.testing.start` runs the real server once for all the tests of
//! the project, on a free port: middlewares, routes, templates and the
//! error handler all take part. Each test asks for the app and sends it
//! requests:
//!
//!     var res = try app.get("/posts");
//!     var res = try app.postForm("/posts/create", .{ .name = "A post" });
//!     var res = try app.request(.{ .method = "DELETE", .target = "/posts/1" });
//!
//! and checks the answer: res.status, res.body, res.header("Location"),
//! res.cookie("session"), res.expectStatus(200), res.expectContains("..."),
//! res.expectRedirect("/posts"). A redirect is not followed.
const std = @import("std");
const spider = @import("spider");
const main = @import("main.zig");

/// What main() does to serve.
fn run() !void {
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    const io = threaded.io();

    try main.serve(gpa, io);
}

test "the shelf lists every book as a card, inside the layout" {
    const app = try spider.testing.start(run);

    var res = try app.get("/");
    defer res.deinit();
    try res.expectStatus(200);
    try res.expectContains("My shelf <span class=\"text-stone-400\">(4)</span>");
    try res.expectContains("<a href=\"/books/2\" class=\"hover:underline\">Piranesi</a>");
    try res.expectContains("Susanna Clarke · 2020");
    try res.expectContains(">Finished</span>");
    try res.expectContains(">Unread</span>");
    try res.expectContains("<a href=\"/about\""); // the layout's nav
}

test "a book has its own page" {
    const app = try spider.testing.start(run);

    var res = try app.get("/books/3");
    defer res.deinit();
    try res.expectStatus(200);
    try res.expectContains("<h1 class=\"text-3xl font-semibold mt-4\">The Peregrine</h1>");
    try res.expectContains("You're still reading this one.");
}

test "a book that does not exist, and an id that is not a number, are the 404 page" {
    const app = try spider.testing.start(run);

    for ([_][]const u8{ "/books/99", "/books/banana", "/nowhere" }) |path| {
        var res = try app.get(path);
        defer res.deinit();
        try res.expectStatus(404);
        try res.expectContains("<h1 class=\"text-2xl font-semibold\">Not found</h1>");
        try res.expectContains(path);
    }
}

test "the about page" {
    const app = try spider.testing.start(run);

    var res = try app.get("/about");
    defer res.deinit();
    try res.expectStatus(200);
    try res.expectContains("A small reading list, built in Zig with Spider.");
}

test "the API: plain text and JSON" {
    const app = try spider.testing.start(run);

    var health = try app.get("/api/health");
    defer health.deinit();
    try health.expectStatus(200);
    try std.testing.expectEqualStrings("ok", health.body);

    var books = try app.get("/api/books");
    defer books.deinit();
    try books.expectStatus(200);
    try std.testing.expectEqualStrings("application/json", books.header("Content-Type").?);
    try books.expectContains("{\"id\":2,\"title\":\"Piranesi\",\"author\":\"Susanna Clarke\",\"year\":2020,\"finished\":true}");
}
