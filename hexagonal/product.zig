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
