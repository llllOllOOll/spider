const std = @import("std");
const spider = @import("spider");

const Spider = spider.Spider;
const Response = spider.Response;
const Request = spider.Request;

const Pong = struct {
    message: []const u8,
};

fn pingHandler(allocator: std.mem.Allocator, req: *Request) !Response {
    _ = req;
    const pong = Pong{ .message = "pong" };
    return try Response.json(allocator, pong);
}

pub fn main(init: std.process.Init) !void {
    var app = try Spider.init(init.gpa, init.io, "0.0.0.0", 8081);
    defer app.deinit();

    app.get("/ping", pingHandler)
        .listen() catch |err| return err;
}
