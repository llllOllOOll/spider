const std = @import("std");
const builtin = @import("builtin");

/// Sets the execute permission on `path`. Windows has no such permission
/// (a program runs by its file type), so there it does nothing.
pub fn makeExecutable(io: std.Io, path: []const u8) !void {
    if (builtin.os.tag == .windows) return;
    const dir = std.Io.Dir.cwd();
    try dir.setFilePermissions(io, path, .executable_file, .{});
}
