const std = @import("std");
const testing = std.testing;
const spider_pg = @import("spider_pg");
const users = @import("users.zig");

test "User.register creates a new user" {
    const allocator = testing.allocator;

    const pool = try spider_pg.Pool.init(allocator, .{
        .hostname = "localhost",
        .username = "postgres",
        .password = "postgres",
        .database = "test_db",
    });
    defer pool.deinit();

    const repo = users.UserRepository.init(allocator, &pool);

    const input = users.CreateUserInput{
        .email = "test@example.com",
        .name = "Test User",
    };

    const user = try repo.register(input);

    try testing.expect(user.email.len > 0);
    try testing.expect(user.name.len > 0);
}
