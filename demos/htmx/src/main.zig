const std = @import("std");
const Io = std.Io;

const htmx = @import("htmx");

const spider = @import("spider");

pub const spider_templates = @import("embedded_templates.zig").EmbeddedTemplates;

const Count = struct {
    count: i32,
};

var count = Count{ .count = 0 };

pub fn main(_: std.process.Init) !void {
    var server = spider.app();
    defer server.deinit();

    server
        .get("/", home)
        .post("/count", countH)
        .listen(3002) catch |err| return err;
}

fn countH(c: *spider.Ctx) !spider.Response {
    count.count += 1;
    return c.render("Count: { count }", count, .{});
}

fn home(c: *spider.Ctx) !spider.Response {
    count.count += 1;
    return c.view("view/index", count, .{});
}
