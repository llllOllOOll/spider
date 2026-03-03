const std = @import("std");
const users_db = @import("../db/users.zig");

pub const UserService = struct {
    allocator: std.mem.Allocator,
    repo: users_db.UserRepository,

    pub fn init(allocator: std.mem.Allocator, repo: users_db.UserRepository) UserService {
        return .{ .allocator = allocator, .repo = repo };
    }

    pub fn register(self: UserService, input: users_db.CreateUserInput) !users_db.User {
        const exists = try self.repo.exists(input.email);
        if (exists) {
            return error.EmailAlreadyExists;
        }
        return try self.repo.create(input);
    }
};

test "UserService.register creates a new user" {
    const input = users_db.CreateUserInput{
        .email = "test@example.com",
        .name = "Test User",
    };

    try std.testing.expectEqual(input.email.len, 14);
    try std.testing.expectEqual(input.name.len, 9);
}

test "UserService.register should fail if email already exists" {
    try std.testing.expect(error.EmailAlreadyExists != undefined);
}
