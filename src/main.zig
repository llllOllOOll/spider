const std = @import("std");
const spider = @import("spider");
const web = spider.web;

fn indexHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    return web.Response.text(allocator, "Hello from Spider!");
}

fn corsMiddleware(allocator: std.mem.Allocator, req: *web.Request, next: web.NextFn) !web.Response {
    var res = try next(allocator, req);
    try res.headers.set(allocator, "Access-Control-Allow-Origin", "*");
    return res;
}

pub fn main(init: std.process.Init) !void {
    var app = try spider.Spider.init(init.gpa, init.io, 8080);
    defer app.deinit();

    app.use(corsMiddleware)
        .get("/", indexHandler)
        .listen() catch |err| return err;
}
