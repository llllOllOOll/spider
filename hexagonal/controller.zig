const std = @import("std");
const spider = @import("spider");
const Response = spider.Response;
const Request = spider.Request;

const product_service = @import("usecase/product.zig");
const Product = product_service.Product;
const CreateProductInput = product_service.CreateProductInput;
const ProductService = product_service.ProductService;
const ProductRepository = product_service.ProductRepository;

var repo: ProductRepository = undefined;
var service: ProductService = undefined;

pub fn initService(allocator: std.mem.Allocator) void {
    repo = ProductRepository.initWithData(allocator);
    service = ProductService.init(repo);
}

pub fn list(allocator: std.mem.Allocator, req: *Request) !Response {
    _ = req;
    return try Response.json(allocator, service.list());
}

pub fn getById(allocator: std.mem.Allocator, req: *Request) !Response {
    const id_str = req.param("id") orelse {
        var res = try Response.text(allocator, "Missing id");
        res.status = .bad_request;
        return res;
    };

    const id = std.fmt.parseInt(u64, id_str, 10) catch {
        var res = try Response.text(allocator, "Invalid id");
        res.status = .bad_request;
        return res;
    };

    const product = service.getById(id);
    if (product) |p| {
        return try Response.json(allocator, p);
    }

    var res = try Response.text(allocator, "Product not found");
    res.status = .not_found;
    return res;
}

pub fn create(allocator: std.mem.Allocator, req: *Request) !Response {
    const input = req.bindJson(allocator, CreateProductInput) catch {
        var res = try Response.text(allocator, "Invalid JSON");
        res.status = .bad_request;
        return res;
    };

    const result = service.create(input) catch |err| {
        var res = try Response.text(allocator, switch (err) {
            error.InvalidName => "Name cannot be empty",
            error.InvalidPrice => "Price must be greater than 0",
            else => "Error creating product",
        });
        res.status = .bad_request;
        return res;
    };

    return try Response.json(allocator, result);
}

pub fn update(allocator: std.mem.Allocator, req: *Request) !Response {
    const id_str = req.param("id") orelse {
        var res = try Response.text(allocator, "Missing id");
        res.status = .bad_request;
        return res;
    };

    const id = std.fmt.parseInt(u64, id_str, 10) catch {
        var res = try Response.text(allocator, "Invalid id");
        res.status = .bad_request;
        return res;
    };

    const input = req.bindJson(allocator, CreateProductInput) catch {
        var res = try Response.text(allocator, "Invalid JSON");
        res.status = .bad_request;
        return res;
    };

    const result = service.update(id, input) catch |err| {
        var res = try Response.text(allocator, switch (err) {
            error.InvalidName => "Name cannot be empty",
            error.InvalidPrice => "Price must be greater than 0",
            error.NotFound => "Product not found",
        });
        res.status = .bad_request;
        return res;
    };

    return try Response.json(allocator, result);
}

pub fn delete(allocator: std.mem.Allocator, req: *Request) !Response {
    const id_str = req.param("id") orelse {
        var res = try Response.text(allocator, "Missing id");
        res.status = .bad_request;
        return res;
    };

    const id = std.fmt.parseInt(u64, id_str, 10) catch {
        var res = try Response.text(allocator, "Invalid id");
        res.status = .bad_request;
        return res;
    };

    service.delete(id) catch {
        var res = try Response.text(allocator, "Product not found");
        res.status = .not_found;
        return res;
    };

    var res = try Response.text(allocator, "Deleted");
    res.status = .no_content;
    return res;
}
