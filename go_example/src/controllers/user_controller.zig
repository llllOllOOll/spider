const std = @import("std");
const spider = @import("spider");
const user_service = @import("../services/user_service.zig");
const model = @import("../models/user.zig");

const register_tmpl = @embedFile("../views/register.html");
const home_tmpl = @embedFile("../views/home.html");

pub const UserController = struct {
    svc: user_service.UserService,

    pub fn registerPage(_: UserController, alc: std.mem.Allocator, _: *spider.Request) !spider.Response {
        return spider.renderBlock(alc, register_tmpl, "register", .{});
    }

    pub fn register(self: UserController, alc: std.mem.Allocator, req: *spider.Request) !spider.Response {
        const input = RegisterRequest.fromRequest(alc, req) catch |err| return switch (err) {
            error.MissingEmail => spider.Response.text(alc, "Email is required"),
            error.MissingName => spider.Response.text(alc, "Name is required"),
            else => spider.Response.text(alc, "Invalid request"),
        };

        const user = self.svc.register(input.toCreateInput()) catch |err| {
            std.log.err("Registration failed: {}", .{err});
            const msg = switch (err) {
                error.EmailAlreadyExists => "Email already exists",
                else => "Internal server error",
            };
            return renderError(alc, register_tmpl, "register_error", msg);
        };

        const location = try std.fmt.allocPrint(alc, "/home?id={d}", .{user.id});
        return spider.Response.redirect(alc, location);
    }

    pub fn home(self: UserController, alc: std.mem.Allocator, req: *spider.Request) !spider.Response {
        const id_str = (try req.queryParam("id", alc)) orelse return spider.Response.text(alc, "Missing user id");
        const id = std.fmt.parseInt(u64, id_str, 10) catch return spider.Response.text(alc, "Invalid user id");

        const user = self.svc.findById(id) catch |err| {
            std.log.err("Failed to fetch user {}: {}", .{ id, err });
            return spider.Response.text(alc, "Error fetching user");
        } orelse return spider.Response.text(alc, "User not found");

        return spider.renderBlock(alc, home_tmpl, "home", user);
    }
};

const RegisterRequest = struct {
    email: []const u8,
    name: []const u8,

    fn fromRequest(alc: std.mem.Allocator, req: *spider.Request) !RegisterRequest {
        const email = (try req.formParam("email", alc)) orelse return error.MissingEmail;
        const name = (try req.formParam("name", alc)) orelse return error.MissingName;
        return .{ .email = email, .name = name };
    }

    fn toCreateInput(self: RegisterRequest) model.CreateUserInput {
        return .{ .email = self.email, .name = self.name };
    }
};

fn renderError(alc: std.mem.Allocator, tmpl: []const u8, block: []const u8, message: []const u8) !spider.Response {
    return spider.renderBlock(alc, tmpl, block, .{ .message = message });
}
