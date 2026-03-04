pub const User = struct {
    id: u64,
    email: []const u8,
    name: []const u8,
};

pub const CreateUserInput = struct {
    email: []const u8,
    name: []const u8,
};

pub const UpdateUserInput = struct {
    email: ?[]const u8 = null,
    name: ?[]const u8 = null,
};
