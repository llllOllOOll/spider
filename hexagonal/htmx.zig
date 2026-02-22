const std = @import("std");
const spider = @import("spider");
const Response = spider.Response;
const Request = spider.Request;
const Context = spider.Context;

const product_service = @import("usecase/product.zig");
const ProductRepository = product_service.ProductRepository;
const CreateProductInput = product_service.CreateProductInput;

var service: product_service.ProductService = undefined;

pub fn initService(allocator: std.mem.Allocator, repo: ProductRepository) void {
    _ = allocator;
    service = product_service.ProductService.init(repo);
}

const Templates = struct {
    home_html: []const u8 = @embedFile("templates/home.html"),
    product_item: []const u8 = @embedFile("templates/product_item.html"),
};

pub fn home(allocator: std.mem.Allocator, req: *Request) !Response {
    _ = req;
    var context = Context.init();
    defer context.deinit(allocator);

    const tmpl = Templates{};
    const result = try spider.template.renderWith(tmpl.home_html, &context, allocator, tmpl);
    return try Response.html(allocator, result);
}

pub fn productList(allocator: std.mem.Allocator, req: *Request) !Response {
    _ = req;
    const products = try service.list();
    defer {
        for (products) |p| allocator.free(p.name);
        allocator.free(products);
    }

    var items = std.ArrayList(*Context).empty;
    defer items.deinit(allocator);

    for (products) |p| {
        var item = try allocator.create(Context);
        item.* = Context.init();
        const name_copy = try allocator.dupe(u8, p.name);
        errdefer allocator.free(name_copy);
        try item.set(allocator, "name", name_copy);
        const price_str = try std.fmt.allocPrint(allocator, "{d:.2}", .{p.price});
        errdefer allocator.free(price_str);
        try item.set(allocator, "price", price_str);
        try items.append(allocator, item);
    }

    var context = Context.init();
    defer context.deinit(allocator);
    try context.setList(allocator, "items", items);

    const tmpl = Templates{};
    const result = try spider.template.renderWith("{% for item in items %}{% include \"product_item\" %}{% endfor %}", &context, allocator, tmpl);
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

    var item = try allocator.create(Context);
    item.* = Context.init();
    try item.set(allocator, "name", result.name);
    const price_str2 = try std.fmt.allocPrint(allocator, "{d:.2}", .{result.price});
    defer allocator.free(price_str2);
    try item.set(allocator, "price", price_str2);

    var context = Context.init();
    defer context.deinit(allocator);
    try context.setObject(allocator, "item", item);

    const tmpl = Templates{};
    const html = try spider.template.renderWith("{% include \"product_item\" %}", &context, allocator, tmpl);
    return try Response.html(allocator, html);
}
