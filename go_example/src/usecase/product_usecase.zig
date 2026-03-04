const Product = @import("../models/product.zig").Product;
const ProductRepository = @import("../repositories/product_repository.zig").ProductRepository;

const ProductUsecase = @This();

repo: ProductRepository,

pub fn init(repo: ProductRepository) ProductUsecase {
    return .{ .repo = repo };
}

pub fn getProducts(self: ProductUsecase) ![]Product {
    return self.repo.findAll();
}
