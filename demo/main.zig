const std = @import("std");
const spider = @import("spider");
const web = spider.web;

fn indexHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    return try web.Response.html(allocator, "<h1>Hello from Spider!</h1>");
}

fn helloHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    return try web.Response.text(allocator, "Hello, World!");
}

fn jsonHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    return try web.Response.json(allocator, .{ .message = "ok", .version = "0.1.0" });
}

pub fn main(init: std.process.Init) !void {
    var app = try spider.Spider.init(init.gpa, init.io, 8080);
    defer app.deinit();

    app.get("/", indexHandler)
        .get("/hello", helloHandler)
        .get("/json", jsonHandler)
        .listen() catch |err| return err;
}
