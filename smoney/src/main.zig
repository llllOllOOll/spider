const std = @import("std");
const db = @import("db/conn.zig");
const users = @import("db/users.zig");
const spider = @import("spider");
const Spider = spider.Spider;
const Response = spider.Response;
const Request = spider.Request;
const dashboard = @import("routes/dashboard.zig");
const seed = @import("seed.zig");

var pool: db.Pool = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    pool = try db.connect(init.gpa);
    defer pool.deinit();

    // Find or create default user
    const repo = users.UserRepository.init(allocator, &pool);
    var user = try repo.findByEmail("dev@local");

    if (user == null) {
        const created = try repo.create(.{ .email = "dev@local", .name = "Dev User" });
        user = created;
        std.log.info("Created user: id={d}", .{user.?.id});
    } else {
        std.log.info("Found user: id={d}", .{user.?.id});
    }

    defer {
        init.gpa.free(user.?.email);
        init.gpa.free(user.?.name);
    }

    dashboard.init(&pool, user.?.id);

    // Seed CSVs if bank is empty
    try seed.run(io, init.gpa, &pool, user.?.id);

    var app = try Spider.init(init.gpa, io, "0.0.0.0", 8080);
    defer app.deinit();

    app.get("/up", healthCheck)
        .get("/dashboard", dashboard.dashboardHandler)
        .get("/dashboard/data", dashboard.dashboardDataHandler)
        .get("/details", dashboard.detailsHandler)
        .listen() catch |err| return err;
}

fn healthCheck(alloc: std.mem.Allocator, req: *Request) !Response {
    _ = req;
    return try Response.text(alloc, "OK");
}
// const std = @import("std");
// const db = @import("db/conn.zig");
// const spider = @import("spider");
//
// const repository = @import("repository.zig");
// const env = @import("config/env.zig");
//
// const Spider = spider.Spider;
// const Response = spider.Response;
// const Request = spider.Request;
//
// const check_product_tmpl = @embedFile("templates/check_product.html");
// const add_product_tmpl = @embedFile("templates/add_product.html");
//
// var global_pool: *db.Pool = undefined;
// var global_repo: repository.ProductRepository = undefined;
//
// pub fn main(init: std.process.Init) !void {
//     var pool = try db.connect(init.gpa);
//     global_pool = &pool;
//     defer pool.deinit();
//
//     var repo = repository.ProductRepository.init(init.gpa, &pool);
//     global_repo = repo;
//     try repo.createTable();
//
//     const server_config = env.getServerConfig();
//
//     var app = try Spider.init(init.gpa, init.io, server_config.host, server_config.port);
//     defer app.deinit();
//
//     app.get("/up", healthCheck)
//         .get("/", helloWorld)
//         .get("/products", listProducts)
//         .get("/products/new", newProductForm)
//         .get("/products/check", checkProduct)
//         .post("/products", addProduct).listen() catch |err| return err;
// }
//
// const Templates = struct {
//     list_products: []const u8 = @embedFile("templates/list_products.html"),
//     new_product: []const u8 = @embedFile("templates/new_product.html"),
// };
//
// fn checkProduct(allocator: std.mem.Allocator, req: *Request) !Response {
//     const name = (try req.queryParam("name", allocator)) orelse return Response.text(allocator, "");
//
//     const result = try global_repo.getByName(name);
//
//     const html = try spider.template.render(check_product_tmpl, .{ .product = result }, allocator);
//     return try Response.html(allocator, html);
// }
//
// fn listProducts(allocator: std.mem.Allocator, req: *Request) !Response {
//     _ = req;
//     const products = try global_repo.findAll();
//     const tmpl = Templates{};
//     const html = try spider.template.render(tmpl.list_products, products, allocator);
//     return try Response.html(allocator, html);
// }
//
// fn newProductForm(allocator: std.mem.Allocator, req: *Request) !Response {
//     _ = req;
//     const tmpl = Templates{};
//     return try Response.html(allocator, tmpl.new_product);
// }
// fn saveProduct(allocator: std.mem.Allocator, req: *Request) !Response {
//     const name = (try req.formParam("name", allocator)) orelse return Response.text(allocator, "Missing name");
//     const price = (try req.formParam("price", allocator)) orelse return Response.text(allocator, "Missing price");
//
//     const product = try global_repo.create(.{ .name = name, .price = price });
//
//     const html = try std.fmt.allocPrint(allocator, "<li><span class=\"tag is-primary\">{s}</span> - ${s}</li>", .{ product.name, product.price });
//     return try Response.html(allocator, html);
// }
//
// fn addProduct(allocator: std.mem.Allocator, req: *Request) !Response {
//     const name = (try req.formParam("name", allocator)) orelse return Response.text(allocator, "Missing name");
//     const price = (try req.formParam("price", allocator)) orelse return Response.text(allocator, "Missing price");
//
//     const product = try global_repo.create(.{ .name = name, .price = price });
//
//     const html = try spider.template.render(add_product_tmpl, product, allocator);
//     return try Response.html(allocator, html);
// }
//
// fn helloWorld(allocator: std.mem.Allocator, req: *Request) !Response {
//     _ = req;
//     return try Response.html(allocator, "<html><body><h1>Hello Seven!</h1></body></html>");
// }
//
// fn healthCheck(allocator: std.mem.Allocator, req: *Request) !Response {
//     _ = req;
//     return try Response.text(allocator, "OK");
// }
