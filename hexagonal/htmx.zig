const std = @import("std");
const spider = @import("spider");
const Response = spider.Response;
const Request = spider.Request;

const product_service = @import("usecase/product.zig");
const ProductRepository = product_service.ProductRepository;
const CreateProductInput = product_service.CreateProductInput;

var service: product_service.ProductService = undefined;

pub fn initService(allocator: std.mem.Allocator, repo: ProductRepository) void {
    _ = allocator;
    service = product_service.ProductService.init(repo);
}

pub fn home(allocator: std.mem.Allocator, req: *Request) !Response {
    _ = req;
    const html = "<html><head><script src=\"https://unpkg.com/htmx.org@1.9.10\"></script></head><body><h1>Product Manager</h1><form hx-post=\"/products\" hx-target=\"#products\" hx-swap=\"beforeend\"><input name=\"name\" placeholder=\"Name\" required><input name=\"price\" type=\"number\" step=\"0.01\" placeholder=\"Price\" required><button>Add</button></form><ul id=\"products\" hx-get=\"/products/list\" hx-trigger=\"load\"></ul></body></html>";
    return try Response.html(allocator, html);
}

pub fn productList(allocator: std.mem.Allocator, req: *Request) !Response {
    _ = req;
    const products = try service.list();
    defer {
        for (products) |p| allocator.free(p.name);
        allocator.free(products);
    }
    var html_list = std.ArrayList(u8).empty;
    defer html_list.deinit(allocator);
    for (products) |p| {
        try html_list.appendSlice(allocator, "<li>");
        try html_list.appendSlice(allocator, p.name);
        try html_list.appendSlice(allocator, " - $");
        const price_str = try std.fmt.allocPrint(allocator, "{d:.2}", .{p.price});
        defer allocator.free(price_str);
        try html_list.appendSlice(allocator, price_str);
        try html_list.appendSlice(allocator, "</li>");
    }
    const result = try allocator.dupe(u8, html_list.items);
    return try Response.html(allocator, result);
}

fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = try allocator.alloc(u8, input.len);
    var j: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '%' and i + 2 < input.len) {
            const byte = std.fmt.parseInt(u8, input[i + 1 ..][0..2], 16) catch {
                output[j] = input[i];
                j += 1;
                continue;
            };
            output[j] = byte;
            j += 1;
            i += 2;
        } else if (input[i] == '+') {
            output[j] = ' ';
            j += 1;
        } else {
            output[j] = input[i];
            j += 1;
        }
    }
    return output[0..j];
}

pub fn createProduct(allocator: std.mem.Allocator, req: *Request) !Response {
    const body = req.body orelse {
        return try Response.text(allocator, "Missing body");
    };
    var params = std.StringHashMap([]const u8).init(allocator);
    defer params.deinit();
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        if (kv.next()) |key| {
            if (kv.next()) |val| {
                const decoded = try percentDecode(allocator, val);
                errdefer allocator.free(decoded);
                try params.put(key, decoded);
            }
        }
    }
    const name = params.get("name") orelse return try Response.text(allocator, "Missing name");
    const price_str = params.get("price") orelse return try Response.text(allocator, "Missing price");
    const price = std.fmt.parseFloat(f64, price_str) catch return try Response.text(allocator, "Invalid price");
    const input = CreateProductInput{ .name = name, .price = price, .quantity = 0 };
    const result = service.create(input) catch return try Response.text(allocator, "Error creating product");
    const li = try std.fmt.allocPrint(allocator, "<li>{s} - ${d:.2}</li>", .{ result.name, result.price });
    return try Response.html(allocator, li);
}
