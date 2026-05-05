const std = @import("std");
const spider = @import("spider");
pub const spider_templates = @import("embedded_templates.zig").EmbeddedTemplates;
const db = spider.pg;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    try db.init(arena, io, .{
        .host = spider.env.getOr("PG_HOST", "localhost"),
        .port = spider.env.getInt(u16, "PG_PORT", 5434),
        .user = spider.env.getOr("PG_USER", "spider"),
        .password = spider.env.getOr("PG_PASSWORD", "spider"),
        .database = spider.env.getOr("PG_DB", "spiderdb"),
        .pool_size = 20,
    });
    defer db.deinit();

    var server = spider.app();
    defer server.deinit();

    server
        .get("/", homeHandler)
        .get("/bills", bills)
        .listen(3000) catch {};
}

const User = struct {
    name: []const u8,
    email: []const u8,
    active: bool,
};

const Count = struct {
    count: i32,
};

const Bill = struct {
    id: i32,
    title: []const u8,
    due_date: []const u8,
    amount: f64,
    status: []const u8,
};

var count = Count{ .count = 0 };

fn homeHandler(c: *spider.Ctx) !spider.Response {
    count.count += 1;
    const users = try db.query(User, c.arena, "Select name, email from users", .{});
    return c.view("home/index", .{
        .count = count.count,
        .users = users,
    }, .{});
}

fn bills(c: *spider.Ctx) !spider.Response {
    const bills_data = try db.query(Bill, c.arena,
        \\SELECT id, title::text, due_date, amount, status FROM bills ORDER BY due_date LIMIT 10
    , .{});
    std.debug.print("bills count: {d}\n", .{bills_data.len});
    if (bills_data.len > 0) {
        std.debug.print("first bill: title={s}\n", .{bills_data[0].title});
    }
    return c.view("bills/index", .{ .bills = bills_data, .title = "Bills" }, .{});
}
