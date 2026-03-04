const std = @import("std");
const model = @import("../models/user.zig");
const users_repo = @import("../repositories/users.zig");

pub const UserService = struct {
    allocator: std.mem.Allocator,
    repo: users_repo.UserRepository,

    pub fn init(allocator: std.mem.Allocator, repo: users_repo.UserRepository) UserService {
        return .{ .allocator = allocator, .repo = repo };
    }

    pub fn register(self: UserService, input: model.CreateUserInput) !model.User {
        const exists = try self.repo.exists(input.email);
        if (exists) return error.EmailAlreadyExists;
        return self.repo.create(input);
    }

    pub fn findById(self: UserService, id: u64) !?model.User {
        return self.repo.findById(id);
    }
};
