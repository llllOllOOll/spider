const std = @import("std");

pub const Body = union(enum) {
    raw: []const u8,
    json: []const u8,
    form: []const [2][]const u8,
};

pub fn jsonBody(serialized: []const u8) Body {
    return .{ .json = serialized };
}
