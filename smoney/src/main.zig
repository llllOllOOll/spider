const std = @import("std");
const db = @import("db/conn.zig");
const users = @import("db/users.zig");
const spider = @import("spider");
const Spider = spider.Spider;
const Response = spider.Response;
const Request = spider.Request;
const txns = @import("db/transactions.zig");
const dashboard = @import("routes/dashboard.zig");

var pool: db.Pool = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    pool = try db.connect(init.gpa);
    defer pool.deinit();

    const repo = users.UserRepository.init(init.gpa, &pool);

    // Find or create user
    var user = try repo.findByEmail("test@smoney.dev");
    if (user == null) {
        user = try repo.create(.{ .email = "test@smoney.dev", .name = "Test User" });
    } else {
        std.log.info("Found existing user", .{});
    }
    defer {
        init.gpa.free(user.?.email);
        init.gpa.free(user.?.name);
    }
    std.log.info("User: id={d} email={s} name={s}", .{ user.?.id, user.?.email, user.?.name });

    dashboard.init(&pool, user.?.id);

    // Teste: buscar por id
    if (try repo.findById(user.?.id)) |found| {
        defer {
            init.gpa.free(found.email);
            init.gpa.free(found.name);
        }
        std.log.info("Found by id: {s}", .{found.email});
    }

    // Teste: buscar por email
    if (try repo.findByEmail("test@smoney.dev")) |found| {
        defer {
            init.gpa.free(found.email);
            init.gpa.free(found.name);
        }
        std.log.info("Found by email: {s}", .{found.name});
    }

    // Teste: exists
    const ok = try repo.exists("test@smoney.dev");
    std.log.info("Exists: {}", .{ok});

    // Teste: update
    if (try repo.update(user.?.id, .{ .name = "Updated User" })) |updated| {
        defer {
            init.gpa.free(updated.email);
            init.gpa.free(updated.name);
        }
        std.log.info("Updated: id={d} name={s}", .{ updated.id, updated.name });
    }

    // Teste: transactions
    const tx_repo = txns.TransactionRepository.init(init.gpa, &pool);

    const tx = try tx_repo.create(.{
        .user_id = user.?.id,
        .date = "2025-07-02",
        .title = "Economart",
        .amount = 1327.46,
        .competencia_year = 2025,
        .competencia_month = 7,
        .is_expense = true,
    });
    defer {
        init.gpa.free(tx.date);
        init.gpa.free(tx.title);
    }
    std.log.info("Created tx: id={d} title={s} amount={d:.2}", .{ tx.id, tx.title, tx.amount });

    const summaries = try tx_repo.getMonthlySummary(user.?.id);
    defer init.gpa.free(summaries);
    for (summaries) |s| {
        std.log.info("Summary: {d}/{d} total={d:.2} count={d}", .{ s.month, s.year, s.total, s.count });
    }

    const parser = @import("finance/parser.zig");

    const csv_files = [_][]const u8{
        "/home/seven/Downloads/nubank/Nubank_2025-07-27.csv",
        "/home/seven/Downloads/nubank/Nubank_2025-08-27.csv",
        "/home/seven/Downloads/nubank/Nubank_2025-09-27.csv",
        "/home/seven/Downloads/nubank/Nubank_2025-10-27.csv",
        "/home/seven/Downloads/nubank/Nubank_2025-11-27.csv",
        "/home/seven/Downloads/nubank/Nubank_2025-12-27.csv",
        "/home/seven/Downloads/nubank/Nubank_2026-01-27.csv",
        "/home/seven/Downloads/nubank/Nubank_2026-02-27.csv",
    };

    for (csv_files) |csv_path| {
        const parsed = try parser.parseCSV(init.io, init.gpa, csv_path, user.?.id);
        defer {
            for (parsed) |p| {
                init.gpa.free(p.date);
                init.gpa.free(p.title);
            }
            init.gpa.free(parsed);
        }
        std.log.info("Parsed {d} transactions from {s}", .{ parsed.len, csv_path });
        for (parsed) |p| {
            _ = try tx_repo.create(p);
        }
    }

    const summaries2 = try tx_repo.getMonthlySummary(user.?.id);
    defer init.gpa.free(summaries2);
    std.log.info("=== MONTHLY SUMMARY ===", .{});
    for (summaries2) |s| {
        std.log.info("{d}/{d}  total={d:.2}  count={d}", .{ s.month, s.year, s.total, s.count });
    }

    var app = try Spider.init(init.gpa, io, "127.0.0.1", 8080);
    defer app.deinit();

    app.get("/up", healthCheck)
        .get("/dashboard", dashboard.dashboardHandler)
        .get("/dashboard/data", dashboard.dashboardDataHandler)
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
