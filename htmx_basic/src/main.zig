const std = @import("std");
const spider = @import("spider");
const db = @import("db/conn.zig");
const db_pool = @import("db/pool.zig");
const db_migrate = @import("db/migrate.zig");
const users_repo = @import("repositories/users.zig");
const user_service = @import("services/user_service.zig");
const user_controller = @import("controllers/user_controller.zig");

var controller: user_controller.UserController = undefined;

pub fn main(init: std.process.Init) !void {
    const alc = init.gpa;

    var conn = try db.connect(alc);
    defer conn.deinit();
    db_pool.init(&conn);

    try db_migrate.run(db_pool.get());

    const repo = users_repo.UserRepository.init(alc, db_pool.get());
    const svc = user_service.UserService.init(alc, repo);
    controller = user_controller.UserController{ .svc = svc };

    var app = try spider.Spider.init(alc, init.io, "0.0.0.0", 8080);
    defer app.deinit();

    app.get("/users/register", registerPage)
        .post("/users/register", register)
        .listen() catch |err| return err;
}

fn registerPage(alc: std.mem.Allocator, req: *spider.Request) !spider.Response {
    return controller.registerPage(alc, req);
}

fn register(alc: std.mem.Allocator, req: *spider.Request) !spider.Response {
    return controller.register(alc, req);
}
