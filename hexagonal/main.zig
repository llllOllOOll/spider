const std = @import("std");
const spider = @import("spider");
const repository = @import("repository.zig");
const product_router = @import("router.zig");
const env = @import("config/env.zig");
const db = @import("db/conn.zig");

const Spider = spider.Spider;

const product = @import("controller.zig");
const htmx = @import("htmx.zig");

pub fn main(init: std.process.Init) !void {
    var pool = try db.connect(init.gpa);
    defer pool.deinit();

    var repo = repository.ProductRepository.init(init.gpa, &pool);
    try repo.createTable();

    product.initService(init.gpa, repo);
    htmx.initService(init.gpa, repo);

    const server_config = env.getServerConfig();

    var app = try Spider.init(init.gpa, init.io, server_config.host, server_config.port);
    defer app.deinit();

    try product_router.Router.init(&app);

    std.debug.print("MAIN: Starting server on {s}:{d}\n", .{ server_config.host, server_config.port });
    app.listen() catch |err| {
        std.debug.print("MAIN: listen error: {}\n", .{err});
        return err;
    };
}
