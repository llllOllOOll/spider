const std = @import("std");
const spider = @import("spider");
const web = spider.web;

const dashboard_html = @embedFile("dashboard.html");

fn indexHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    return try web.Response.html(allocator, dashboard_html);
}

var total_requests = std.atomic.Value(u64).init(0);

fn metricsHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    const total = total_requests.fetchAdd(1, .monotonic);
    return try web.Response.json(allocator, .{
        .total_requests = total,
        .port = 8080,
        .threads = std.Thread.getCpuCount() catch 4,
        .avg_latency_us = 0,
        .errors = 0,
    });
}

fn helloHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    _ = total_requests.fetchAdd(1, .monotonic);
    return try web.Response.text(allocator, "Hello, World!");
}

fn jsonHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    _ = total_requests.fetchAdd(1, .monotonic);
    return try web.Response.json(allocator, .{ .message = "ok", .version = "0.1.0" });
}

pub fn main(init: std.process.Init) !void {
    var app = try spider.Spider.init(init.gpa, init.io, 8080);
    defer app.deinit();

    app.get("/", indexHandler)
        .get("/metrics", metricsHandler)
        .get("/hello", helloHandler)
        .get("/json", jsonHandler)
        .listen() catch |err| return err;
}
