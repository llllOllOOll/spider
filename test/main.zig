const std = @import("std");
const spider = @import("spider");

const Spider = spider.Spider;
const Response = spider.Response;
const Request = spider.Request;

pub fn main(init: std.process.Init) !void {
    std.debug.print("test \n", .{});

    var app = try Spider.init(init.gpa, init.io, "127.0.0.1", 8081);
    defer app.deinit();

    app.get("/", helloWorld).listen() catch |err| return err;
}

fn helloWorld(allocator: std.mem.Allocator, req: *Request) !Response {
    _ = req;
    return try Response.html(allocator, "<html><body><h1>Hello Seven</h1></body> </html>");
}
