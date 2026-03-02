const std = @import("std");
const Allocator = std.mem.Allocator;

const spider = @import("spider");

const indexView: []const u8 = @embedFile("views/index.html");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alc = init.gpa;

    const s = try spider.Spider.init(alc, io, "127.0.0.1", 8088);

    s.get("/up", handleUp)
        .get("/", indexController)
        .post("/count", updateCounter)
        .post("/users", userCreate)
        .listen() catch |err| return err;
}

const Count = struct {
    count: i32,
};

var count: Count = Count{ .count = 1 };

fn indexController(alc: Allocator, req: *spider.Request) !spider.Response {
    _ = req;

    return try spider.render(alc, indexView, count);
}

fn updateCounter(alc: Allocator, req: *spider.Request) !spider.Response {
    _ = req;

    count.count += 1;

    return try spider.render(alc, indexView, count);
}

fn userController(alc: Allocator, req: *spider.Request) !spider.Response {
    _ = req;

    const users = [_]User{ .{ .name = "Seven" }, .{ .name = "Maylla" } };
    return try spider.render(alc, indexView, users);
}

fn userCreate(alc: Allocator, req: *spider.Request) !spider.Response {
    const name = try req.formParam("name", alc) orelse "";
    const email = try req.formParam("email", alc) orelse "";

    std.debug.print("name: {s} email: {s}\n", .{ name, email });
    return spider.Response.text(alc, "OK");
}

const User = struct {
    name: []const u8,
};

fn handleUp(alc: Allocator, req: *spider.Request) !spider.Response {
    _ = req;
    return try spider.Response.text(alc, "OK");
}
