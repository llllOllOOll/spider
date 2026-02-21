const std = @import("std");

pub const Product = struct {
    id: u64,
    name: []const u8,
    price: f64,
    quantity: u32,
};

pub const CreateProductInput = struct {
    name: []const u8,
    price: f64,
    quantity: u32,
};

pub const ProductRepository = struct {
    allocator: std.mem.Allocator,
    products: *std.ArrayList(Product),
    next_id: *u64,

    pub fn init(allocator: std.mem.Allocator) ProductRepository {
        return .{
            .allocator = allocator,
            .products = undefined,
            .next_id = undefined,
        };
    }

    pub fn initWithData(allocator: std.mem.Allocator) ProductRepository {
        const products = allocator.create(std.ArrayList(Product)) catch unreachable;
        products.* = .empty;
        products.append(allocator, .{ .id = 1, .name = "Widget", .price = 9.99, .quantity = 100 }) catch {};
        products.append(allocator, .{ .id = 2, .name = "Gadget", .price = 19.99, .quantity = 50 }) catch {};
        products.append(allocator, .{ .id = 3, .name = "Gizmo", .price = 29.99, .quantity = 25 }) catch {};

        const next_id = allocator.create(u64) catch unreachable;
        next_id.* = 4;

        return .{
            .allocator = allocator,
            .products = products,
            .next_id = next_id,
        };
    }

    pub fn deinit(self: ProductRepository) void {
        self.products.deinit();
        self.allocator.destroy(self.products);
        self.allocator.destroy(self.next_id);
    }

    pub fn list(self: ProductRepository) []Product {
        return self.products.items;
    }

    pub fn getById(self: ProductRepository, id: u64) ?Product {
        for (self.products.items) |p| {
            if (p.id == id) return p;
        }
        return null;
    }

    pub fn create(self: ProductRepository, input: CreateProductInput) !Product {
        const new_product = Product{
            .id = self.next_id.*,
            .name = input.name,
            .price = input.price,
            .quantity = input.quantity,
        };
        try self.products.append(self.allocator, new_product);
        self.next_id.* += 1;
        return new_product;
    }

    pub fn update(self: ProductRepository, id: u64, input: CreateProductInput) !Product {
        for (self.products.items, 0..) |p, i| {
            if (p.id == id) {
                self.products.items[i] = Product{
                    .id = id,
                    .name = input.name,
                    .price = input.price,
                    .quantity = input.quantity,
                };
                return self.products.items[i];
            }
        }
        return error.NotFound;
    }

    pub fn delete(self: ProductRepository, id: u64) !void {
        for (self.products.items, 0..) |p, i| {
            if (p.id == id) {
                _ = self.products.orderedRemove(i);
                return;
            }
        }
        return error.NotFound;
    }
};
