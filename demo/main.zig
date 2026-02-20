const std = @import("std");
const spider = @import("spider");
const web = spider.web;
const spider_pg = @import("spider_pg");

var pool: spider_pg.Pool = undefined;

const dashboard_html = @embedFile("dashboard.html");

fn indexHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    return try web.Response.html(allocator, dashboard_html);
}

fn metricsHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    return try web.Response.json(allocator, .{
        .total_requests = @as(u64, 0),
        .port = 8080,
        .threads = std.Thread.getCpuCount() catch 4,
    });
}

fn helloHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    return try web.Response.text(allocator, "Hello, World!");
}

fn jsonHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    return try web.Response.json(allocator, .{ .message = "ok", .version = "0.1.0" });
}

fn usersHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    const conn = try pool.acquire();
    defer pool.release(conn);

    var result = try spider_pg.query(conn, "SELECT id, name FROM users LIMIT 10");
    defer result.deinit();

    const nrows = result.rows();
    const users = try allocator.alloc(struct { id: i32, name: []u8 }, nrows);

    for (0..nrows) |i| {
        const id_str = result.getValue(i, 0);
        const name_str = result.getValue(i, 1);
        users[i] = .{
            .id = try std.fmt.parseInt(i32, id_str, 10),
            .name = try allocator.dupe(u8, name_str),
        };
    }

    return web.Response.json(allocator, users);
}

pub fn main(init: std.process.Init) !void {
    pool = try spider_pg.Pool.init(init.gpa, .{
        .host = "localhost",
        .database = "spider_demo",
        .user = "postgres",
        .password = "postgres",
        .pool_size = 10,
    });
    defer pool.deinit();

    var app = try spider.Spider.init(init.gpa, init.io, 8080);
    defer app.deinit();

    app.get("/", indexHandler)
        .get("/metrics", metricsHandler)
        .get("/hello", helloHandler)
        .get("/json", jsonHandler)
        .get("/users", usersHandler)
        .listen() catch |err| return err;
}
