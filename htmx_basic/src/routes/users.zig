const std = @import("std");
const spider = @import("spider");
const spider_pg = @import("spider_pg");
const users_db = @import("../db/users.zig");
const user_service = @import("../services/user_service.zig");
const user_controller = @import("../controllers/user_controller.zig");

const register_tmpl = @embedFile("../views/register.html");
const home_tmpl = @embedFile("../views/home.html");

pub const UserRouter = struct {
    allocator: std.mem.Allocator,
    pool: *spider_pg.Pool,

    pub fn init(allocator: std.mem.Allocator, pool: *spider_pg.Pool) UserRouter {
        return .{ .allocator = allocator, .pool = pool };
    }

    pub fn registerPage(self: UserRouter, _: *spider.Request) !spider.Response {
        return try spider.renderBlock(self.allocator, register_tmpl, "register", .{});
    }

    pub fn register(self: UserRouter, alc: std.mem.Allocator, req: *spider.Request) !spider.Response {
        const repo = users_db.UserRepository.init(alc, self.pool);
        const svc = user_service.UserService.init(alc, repo);
        return try user_controller.registerHandler(alc, req, svc);
    }

    pub fn home(self: UserRouter, alc: std.mem.Allocator, req: *spider.Request) !spider.Response {
        const repo = users_db.UserRepository.init(alc, self.pool);
        return try user_controller.homeHandler(alc, req, repo);
    }
};
