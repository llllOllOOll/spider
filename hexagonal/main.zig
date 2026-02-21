const std = @import("std");
const c = @cImport(@cInclude("stdlib.h"));
const spider = @import("spider");
const spider_pg = @import("spider_pg");
const repository = @import("repository.zig");

const Spider = spider.Spider;
const Response = spider.Response;
const Request = spider.Request;

const Pong = struct {
    message: []const u8,
};

const product = @import("controller.zig");

fn pingHandler(allocator: std.mem.Allocator, req: *Request) !Response {
    _ = req;
    const pong = Pong{ .message = "pong" };
    return try Response.json(allocator, pong);
}

fn getEnv(key: []const u8, default: []const u8) []const u8 {
    var key_null: [256]u8 = undefined;
    @memcpy(key_null[0..key.len], key);
    key_null[key.len] = 0;
    if (c.getenv(&key_null)) |val| {
        return std.mem.sliceTo(val, 0);
    }
    return default;
}

fn getEnvInt(key: []const u8, default: u16) u16 {
    var key_null: [256]u8 = undefined;
    @memcpy(key_null[0..key.len], key);
    key_null[key.len] = 0;
    if (c.getenv(&key_null)) |val| {
        return std.fmt.parseInt(u16, std.mem.sliceTo(val, 0), 10) catch default;
    }
    return default;
}

fn parseDbUrl(_: std.mem.Allocator, db_url: []const u8) !spider_pg.Config {
    var config = spider_pg.Config{
        .database = "spider",
        .user = "spider",
        .password = "spider",
    };

    if (std.mem.startsWith(u8, db_url, "postgres://")) {
        const after_prefix = db_url[11..];
        var user_end: usize = 0;
        var host_end: usize = 0;

        for (after_prefix, 0..) |ch, i| {
            if (ch == ':' and user_end == 0) {
                user_end = i;
            }
            if (ch == '@') {
                host_end = i;
                break;
            }
        }

        if (user_end > 0 and host_end > user_end) {
            const user_part = after_prefix[0..user_end];
            const pass_start = user_end + 1;
            const pass_end = host_end;
            config.user = user_part;
            config.password = after_prefix[pass_start..pass_end];
        } else if (host_end > 0) {
            config.user = after_prefix[0..host_end];
        }

        const after_at = after_prefix[host_end + 1 ..];
        var db_start: usize = 0;
        for (after_at, 0..) |ch, i| {
            if (ch == '/') {
                db_start = i + 1;
                break;
            }
        }

        if (db_start > 0) {
            config.database = after_at[db_start..];
            const host_port = after_at[0 .. db_start - 1];

            for (host_port, 0..) |ch, i| {
                if (ch == ':') {
                    config.host = host_port[0..i];
                    config.port = try std.fmt.parseInt(u16, host_port[i + 1 ..], 10);
                    break;
                }
            } else {
                config.host = host_port;
            }
        }
    }

    return config;
}

pub fn main(init: std.process.Init) !void {
    const db_url = getEnv("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/spider_demo?sslmode=disable");
    const config = try parseDbUrl(init.gpa, db_url);

    var pool = try spider_pg.Pool.init(init.gpa, config);
    defer pool.deinit();

    var repo = repository.ProductRepository.init(init.gpa, &pool);
    try repo.createTable();

    product.initService(init.gpa, repo);

    const host = getEnv("HOST", "0.0.0.0");
    const port = getEnvInt("PORT", 8081);

    var app = try Spider.init(init.gpa, init.io, host, port);
    defer app.deinit();

    app.get("/ping", pingHandler)
        .get("/products", product.list)
        .get("/products/:id", product.getById)
        .post("/products", product.create)
        .put("/products/:id", product.update)
        .delete("/products/:id", product.delete)
        .listen() catch |err| return err;
}
