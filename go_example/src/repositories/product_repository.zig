const std = @import("std");
const spider_pg = @import("spider_pg");
const db_pool = @import("../db/pool.zig");
const Product = @import("../models/product.zig").Product;

pub const ProductRepository = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ProductRepository {
        return .{ .allocator = allocator };
    }

    pub fn findAll(self: ProductRepository) ![]Product {
        const pool = db_pool.get();
        const conn = try pool.acquire();
        defer pool.release(conn);

        var result = spider_pg.query(conn, "SELECT id, name, price FROM products ORDER BY id") catch |err| {
            std.log.err("findAll failed: {}", .{err});
            return err;
        };
        defer result.deinit();

        const count = result.rows();
        if (count == 0) return &[_]Product{};

        const products = try self.allocator.alloc(Product, count);
        errdefer self.allocator.free(products);

        for (products, 0..) |*product, i| {
            product.* = .{
                .id = try std.fmt.parseInt(i32, result.getValue(i, 0), 10),
                .name = try self.allocator.dupe(u8, result.getValue(i, 1)),
                .price = try std.fmt.parseFloat(f64, result.getValue(i, 2)),
            };
        }

        return products;
    }
};
