const std = @import("std");
const spider_pg = @import("spider_pg");
const users_db = @import("../db/users.zig");
const user_service = @import("../services/user_service.zig");
const user_controller = @import("../controllers/user_controller.zig");

var test_pool: ?*spider_pg.Pool = null;

fn setupIntegration() !void {
    const allocator = std.testing.allocator;
    test_pool = try spider_pg.Pool.init(allocator, .{
        .hostname = "localhost",
        .username = "spider",
        .password = "spider",
        .database = "smoney",
        .port = 5434,
    });

    const conn = try test_pool.?.acquire();
    defer test_pool.?.release(conn);

    _ = try spider_pg.exec(conn, "DROP TABLE IF EXISTS users_integration_test");
    _ = try spider_pg.exec(conn, "CREATE TABLE users_integration_test (id SERIAL PRIMARY KEY, email VARCHAR(255) UNIQUE NOT NULL, name VARCHAR(255) NOT NULL)");
}

fn teardownIntegration() void {
    if (test_pool) |pool| {
        pool.deinit();
        test_pool = null;
    }
}

const MockRequest = struct {
    params: std.StringHashMap([]const u8),

    fn formParam(self: @This(), name: []const u8, alc: std.mem.Allocator) !?[]const u8 {
        _ = alc;
        return self.params.get(name);
    }
};

test "UserController.registerHandler creates user via service and repository" {
    try setupIntegration();
    defer teardownIntegration();

    const allocator = std.testing.allocator;
    const repo = users_db.UserRepository.init(allocator, test_pool.?);
    const service = user_service.UserService.init(allocator, repo);

    var params = std.StringHashMap([]const u8).init(allocator);
    defer params.deinit();
    try params.put("email", "integration@example.com");
    try params.put("name", "Integration Test");

    const mock_req = MockRequest{ .params = params };
    const register_req = try user_controller.parseRegisterRequest(allocator, @ptrCast(&mock_req));

    const input = users_db.CreateUserInput{
        .email = register_req.email,
        .name = register_req.name,
    };

    const user = try service.register(input);

    try std.testing.expect(user.id > 0);
    try std.testing.expectEqualStrings("integration@example.com", user.email);
    try std.testing.expectEqualStrings("Integration Test", user.name);
}

test "UserController.registerHandler returns error when email already exists" {
    const allocator = std.testing.allocator;
    const repo = users_db.UserRepository.init(allocator, test_pool.?);
    const service = user_service.UserService.init(allocator, repo);

    const input = users_db.CreateUserInput{
        .email = "duplicate@example.com",
        .name = "First User",
    };

    _ = try service.register(input);

    const duplicate = service.register(input);
    try std.testing.expectError(error.EmailAlreadyExists, duplicate);
}
