const std = @import("std");
const spider_pg = @import("spider_pg");
const users_db = @import("../db/users.zig");

var test_pool: ?*spider_pg.Pool = null;

fn setup() !void {
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

    _ = try spider_pg.exec(conn, "DROP TABLE IF EXISTS users_test");
    _ = try spider_pg.exec(conn, "CREATE TABLE users_test (id SERIAL PRIMARY KEY, email VARCHAR(255) UNIQUE NOT NULL, name VARCHAR(255) NOT NULL)");
}

fn teardown() void {
    if (test_pool) |pool| {
        pool.deinit();
        test_pool = null;
    }
}

test "UserRepository.create inserts user into database" {
    try setup();
    defer teardown();

    const allocator = std.testing.allocator;
    const repo = users_db.UserRepository.init(allocator, test_pool.?);

    const input = users_db.CreateUserInput{
        .email = "test@example.com",
        .name = "Test User",
    };

    const user = try repo.create(input);

    try std.testing.expect(user.id > 0);
    try std.testing.expectEqualStrings("test@example.com", user.email);
    try std.testing.expectEqualStrings("Test User", user.name);
}
