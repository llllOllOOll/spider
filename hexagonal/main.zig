const std = @import("std");
const c = @cImport(@cInclude("stdlib.h"));
const spider = @import("spider");

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

pub fn main(init: std.process.Init) !void {
    product.initService(init.gpa);

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
