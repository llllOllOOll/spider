const std = @import("std");
const spider = @import("spider");
const web = spider.web;

fn getUser(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    const id = req.param("id") orelse "unknown";
    const body = try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\"}}", .{id});
    return web.Response.json(allocator, body);
}

fn getUserPosts(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    const id = req.param("id") orelse "unknown";
    const body = try std.fmt.allocPrint(allocator, "{{\"user_id\":\"{s}\",\"posts\":[]}}", .{id});
    return web.Response.json(allocator, body);
}

fn createUser(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    return web.Response.text(allocator, "created");
}

fn indexHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    return web.Response.text(allocator, "Hello from Spider!");
}

pub fn main(init: std.process.Init) !void {
    var app = try spider.Spider.init(init.gpa, init.io, 8080);
    defer app.deinit();

    app.get("/", indexHandler)
        .get("/users/:id", getUser)
        .get("/users/:id/posts", getUserPosts)
        .post("/users", createUser)
        .listen() catch |err| return err;
}
