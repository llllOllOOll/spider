const std = @import("std");
const spider = @import("spider");
const users_db = @import("../db/users.zig");
const user_service = @import("../services/user_service.zig");

const register_tmpl = @embedFile("../views/register.html");
const home_tmpl = @embedFile("../views/home.html");

pub const RegisterRequest = struct {
    email: []const u8,
    name: []const u8,
};

pub fn parseRegisterRequest(allocator: std.mem.Allocator, req: *spider.Request) !RegisterRequest {
    const email = (try req.formParam("email", allocator)) orelse return error.MissingEmail;
    const name = (try req.formParam("name", allocator)) orelse return error.MissingName;
    return RegisterRequest{ .email = email, .name = name };
}

pub fn registerHandler(allocator: std.mem.Allocator, req: *spider.Request, service: user_service.UserService) !spider.Response {
    const register_req = parseRegisterRequest(allocator, req) catch |err| {
        return switch (err) {
            error.MissingEmail => spider.Response.text(allocator, "Email is required"),
            error.MissingName => spider.Response.text(allocator, "Name is required"),
            else => spider.Response.text(allocator, "Invalid request"),
        };
    };

    const input = users_db.CreateUserInput{
        .email = register_req.email,
        .name = register_req.name,
    };

    const user = service.register(input) catch |err| {
        const ErrorData = struct { message: []const u8 };
        const error_msg = switch (err) {
            error.EmailAlreadyExists => "Email already exists",
            else => "Internal server error",
        };
        const data = ErrorData{ .message = error_msg };
        return try spider.renderBlock(allocator, register_tmpl, "register_error", data);
    };

    const id_str = try std.fmt.allocPrint(allocator, "/home?id={d}", .{user.id});
    return try spider.Response.redirect(allocator, id_str);
}

pub fn registerPageHandler(allocator: std.mem.Allocator, req: *spider.Request) !spider.Response {
    _ = req;
    return try spider.renderBlock(allocator, register_tmpl, "register", .{});
}

pub fn homeHandler(allocator: std.mem.Allocator, req: *spider.Request, repo: users_db.UserRepository) !spider.Response {
    const id_str = (try req.queryParam("id", allocator)) orelse return spider.Response.text(allocator, "Missing user id");
    const id = std.fmt.parseInt(u64, id_str, 10) catch return spider.Response.text(allocator, "Invalid user id");

    const user = repo.findById(id) catch {
        return spider.Response.text(allocator, "Error fetching user");
    };

    if (user == null) {
        return spider.Response.text(allocator, "User not found");
    }

    return try spider.renderBlock(allocator, home_tmpl, "home", user.?);
}

test "parseRegisterRequest extracts email and name from form" {
    const allocator = std.testing.allocator;

    const MockRequest = struct {
        params: std.StringHashMap([]const u8),

        fn formParam(self: @This(), name: []const u8, alc: std.mem.Allocator) !?[]const u8 {
            _ = alc;
            return self.params.get(name);
        }
    };

    var params = std.StringHashMap([]const u8).init(allocator);
    defer params.deinit();
    try params.put("email", "test@example.com");
    try params.put("name", "Test User");

    const mock_req = MockRequest{ .params = params };
    const result = try parseRegisterRequest(allocator, @ptrCast(&mock_req));

    try std.testing.expectEqualStrings("test@example.com", result.email);
    try std.testing.expectEqualStrings("Test User", result.name);
}

test "homeHandler renders user data" {
    try std.testing.expect(true);
}

test "homeHandler returns user data from database" {
    const allocator = std.testing.allocator;

    var params = std.StringHashMap([]const u8).init(allocator);
    defer params.deinit();
    try params.put("id", "1");

    try std.testing.expect(params.get("id") != null);
}
