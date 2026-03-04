const std = @import("std");
const spider = @import("spider");
const Allocator = std.mem.Allocator;
const db = @import("db/conn.zig");
const db_pool = @import("db/pool.zig");
const db_migrate = @import("db/migrate.zig");
const ProductController = @import("controllers/product_controller.zig");
const ProductUsecase = @import("usecase/product_usecase.zig");

const ProductRepository = @import("repositories/product_repository.zig").ProductRepository;

var productController: ProductController = undefined;

fn pingHandler(alc: Allocator, _: *spider.Request) !spider.Response {
    return spider.Response.json(alc, .{ .msg = "OK" });
}

fn getProducts(alc: Allocator, req: *spider.Request) !spider.Response {
    return productController.getProducts(alc, req);
}

pub fn main(i: std.process.Init) !void {
    const allocator = i.gpa;
    const io = i.io;

    var conn = try db.connect(allocator);
    defer conn.deinit();
    db_pool.init(&conn);
    try db_migrate.run(db_pool.get());

    const repo = ProductRepository.init(allocator);
    const usecase = ProductUsecase.init(repo);
    productController = ProductController.init(allocator, usecase);
    defer productController.deinit();

    const server = try spider.Spider.init(allocator, io, "127.0.0.1", 8080);
    defer server.deinit();

    server.get("/ping", pingHandler)
        .get("/products", getProducts)
        .listen() catch |err| return err;
}
