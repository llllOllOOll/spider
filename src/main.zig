const std = @import("std");
const spider = @import("spider");
const web = spider.web;

fn indexHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    return web.Response.text(allocator, "Hello from Spider!");
}

fn helloHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    return web.Response.text(allocator, "Hello, World!");
}

pub fn main(init: std.process.Init) !void {
    var app = try spider.Spider.init(init.gpa, init.io, "0.0.0.0", 8080);
    defer app.deinit();

    app.use(web.corsMiddleware)
        .use(web.loggerMiddleware)
        .get("/", indexHandler)
        .get("/hello", helloHandler)
        .listen() catch |err| return err;
}
