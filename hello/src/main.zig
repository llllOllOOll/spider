const std = @import("std");
const spider = @import("spider");

const Spider = spider.Spider;
const Response = spider.Response;
const Request = spider.Request;

const check_product_tmpl = @embedFile("templates/check_product.html");

pub fn main(init: std.process.Init) !void {
    var app = try Spider.init(init.gpa, init.io, "0.0.0.0", 8082);
    defer app.deinit();

    _ = app.get("/up", healthCheck);
    _ = app.get("/", helloWorld);
    _ = app.get("/products", listProducts);
    _ = app.get("/products/new", newProductForm);
    _ = app.get("/products/check", checkProduct);
    _ = app.post("/products", addProduct).listen() catch |err| return err;
}

const Templates = struct {
    list_products: []const u8 = @embedFile("templates/list_products.html"),
    new_product: []const u8 = @embedFile("templates/new_product.html"),
};

const MockProducts = struct {
    name: []const u8 = "",
    price: []const u8 = "",
};

var products = [10]MockProducts{
    .{ .name = "Widget", .price = "9.99" },
    .{ .name = "Gadget", .price = "19.99" },
    .{ .name = "Gizmo", .price = "29.99" },
    .{},
    .{},
    .{},
    .{},
    .{},
    .{},
    .{},
};
var products_count: usize = 3;

fn listProducts(allocator: std.mem.Allocator, req: *Request) !Response {
    _ = req;
    const tmpl = Templates{};
    const html = try spider.template.render(tmpl.list_products, products[0..products_count], allocator);
    return try Response.html(allocator, html);
}

fn newProductForm(allocator: std.mem.Allocator, req: *Request) !Response {
    _ = req;
    const tmpl = Templates{};
    return try Response.html(allocator, tmpl.new_product);
}

fn checkProduct(allocator: std.mem.Allocator, req: *Request) !Response {
    const name = req.queryParam("name") orelse return Response.text(allocator, "");

    var result: ?[]const u8 = null;
    for (products[0..products_count]) |p| {
        if (std.mem.eql(u8, p.name, name)) {
            result = p.name;
            break;
        }
    }

    const html = try spider.template.render(check_product_tmpl, .{ .product = result }, allocator);
    return try Response.html(allocator, html);
}

fn addProduct(allocator: std.mem.Allocator, req: *Request) !Response {
    const name = req.formParam("name") orelse return Response.text(allocator, "Missing name");
    const price = req.formParam("price") orelse return Response.text(allocator, "Missing price");

    if (products_count >= 10) {
        return try Response.html(allocator, "<li><span class=\"has-text-warning\">Limit reached</span></li>");
    }

    products[products_count] = .{ .name = try allocator.dupe(u8, name), .price = try allocator.dupe(u8, price) };
    products_count += 1;

    const html = try std.fmt.allocPrint(allocator, "<li><span class=\"tag is-primary\">{s}</span> - ${s}</li>", .{ name, price });
    return try Response.html(allocator, html);
}

fn helloWorld(allocator: std.mem.Allocator, req: *Request) !Response {
    _ = req;
    return try Response.html(allocator, "<html><body><h1>Hello Seven!</h1></body></html>");
}

fn healthCheck(allocator: std.mem.Allocator, req: *Request) !Response {
    _ = req;
    return try Response.text(allocator, "OK");
}
