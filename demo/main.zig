const std = @import("std");
const spider = @import("spider");
const web = spider.web;

// const c = @cImport({
//     @cInclude("time.h");
// });

// Global metrics - atomic for thread safety
var total_requests = std.atomic.Value(u64).init(0);
var start_time: i64 = 0;

const dashboard_html = @embedFile("dashboard.html");

fn indexHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    return try web.Response.html(allocator, dashboard_html);
}

fn readMemoryKb() u64 {
    var buf: [1024]u8 = undefined;
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/status", .{}, 0) catch return 0;
    defer std.posix.close(fd);
    const n = std.posix.read(fd, &buf) catch return 0;
    const content = buf[0..n];
    const marker = "VmRSS:";
    const pos = std.mem.indexOf(u8, content, marker) orelse return 0;
    const line = content[pos + marker.len ..];
    const end = std.mem.indexOf(u8, line, "\n") orelse 20;
    const trimmed = std.mem.trim(u8, line[0..end], " \tkB");
    return std.fmt.parseInt(u64, trimmed, 10) catch 0;
}

fn metricsHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;

    const total = total_requests.fetchAdd(1, .monotonic);
    // const now = c.time(null);
    // const uptime = now - start_time;
    // const rps = if (uptime > 0) total / @as(u64, @intCast(uptime)) else 0;

    // const mem_kb = readMemoryKb();
    return try web.Response.json(allocator, .{
        // .rps = rps,
        .total_requests = total,
        // .uptime_seconds = uptime,
        .port = 8080,
        .threads = std.Thread.getCpuCount() catch 4,
        .avg_latency_us = 0,
        .errors = 0,
        // .memory_mb = mem_kb / 1024,
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
    // start_time = c.time(null);

    var app = try spider.Spider.init(init.gpa, init.io, 8080);
    defer app.deinit();

    app.get("/", indexHandler)
        .get("/metrics", metricsHandler)
        .get("/hello", helloHandler)
        .get("/json", jsonHandler)
        .listen() catch |err| return err;
}
