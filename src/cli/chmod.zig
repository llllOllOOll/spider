const std = @import("std");

pub fn makeExecutable(io: std.Io, path: []const u8) !void {
    const dir = std.Io.Dir.cwd();
    const perms: std.Io.File.Permissions = @enumFromInt(0o755);
    try dir.setFilePermissions(io, path, perms, .{});
}
