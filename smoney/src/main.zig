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
var dashboard_handler: dashboard.DashboardHandler = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    pool = try db.connect(init.gpa);
    defer pool.deinit();

    const repo = users.UserRepository.init(allocator, &pool);
    var user = try repo.findByEmail("dev@local");

    if (user == null) {
        const created = try repo.create(.{ .email = "dev@local", .name = "Dev User" });
        user = created;
        std.log.info("Created user: id={d}", .{user.?.id});
    } else {
        std.log.info("Found user: id={d}", .{user.?.id});
    }

    dashboard_handler = dashboard.createDashboardHandler(&pool, user.?.id);
    defer repo.destroy(user.?);

    try seed.run(io, init.gpa, &pool, user.?.id);

    var app = try Spider.init(init.gpa, io, "0.0.0.0", 8080);
    defer app.deinit();

    app.get("/up", healthCheck)
        .get("/dashboard", dashboardWrapper)
        .get("/dashboard/data", dashboardDataWrapper)
        .get("/details", detailsWrapper)
        .listen() catch |err| return err;
}

fn dashboardWrapper(alloc: std.mem.Allocator, req: *Request) !Response {
    return dashboard_handler.renderDashboard(alloc, req);
}

fn dashboardDataWrapper(alloc: std.mem.Allocator, req: *Request) !Response {
    return dashboard_handler.renderDashboardData(alloc, req);
}

fn detailsWrapper(alloc: std.mem.Allocator, req: *Request) !Response {
    return dashboard_handler.renderDetails(alloc, req);
}

fn healthCheck(alloc: std.mem.Allocator, req: *Request) !Response {
    _ = req;
    return try Response.text(alloc, "OK");
}
