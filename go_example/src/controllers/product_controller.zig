const std = @import("std");
const spider = @import("spider");
const ProductController = @This();
const ProductUsecase = @import("../usecase/product_usecase.zig");

allocator: std.mem.Allocator,
usecase: ProductUsecase,

pub fn init(alc: std.mem.Allocator, usecase: ProductUsecase) ProductController {
    return .{
        .allocator = alc,
        .usecase = usecase,
    };
}

pub fn deinit(_: ProductController) void {}

pub fn getProducts(self: ProductController, alc: std.mem.Allocator, _: *spider.Request) !spider.Response {
    const products = try self.usecase.getProducts();
    return spider.Response.json(alc, products);
}
