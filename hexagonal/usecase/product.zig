const std = @import("std");
const repository = @import("../repository.zig");

pub const Product = repository.Product;
pub const CreateProductInput = repository.CreateProductInput;
pub const ProductRepository = repository.ProductRepository;

pub const ProductService = struct {
    repo: ProductRepository,

    pub fn init(repo: ProductRepository) ProductService {
        return .{ .repo = repo };
    }

    pub fn list(self: *ProductService) []Product {
        return self.repo.list();
    }

    pub fn getById(self: *ProductService, id: u64) ?Product {
        return self.repo.getById(id);
    }

    pub fn create(self: *ProductService, input: CreateProductInput) !Product {
        if (input.name.len == 0) return error.InvalidName;
        if (input.price <= 0) return error.InvalidPrice;

        return try self.repo.create(input);
    }

    pub fn update(self: *ProductService, id: u64, input: CreateProductInput) !Product {
        if (input.name.len == 0) return error.InvalidName;
        if (input.price <= 0) return error.InvalidPrice;

        return try self.repo.update(id, input);
    }

    pub fn delete(self: *ProductService, id: u64) !void {
        return try self.repo.delete(id);
    }
};
