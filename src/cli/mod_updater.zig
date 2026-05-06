const std = @import("std");
const fs_utils = @import("fs_utils.zig");

pub fn updateFeaturesMod(io: std.Io, allocator: std.mem.Allocator, features_dir: std.Io.Dir, feature: []const u8) !void {
    const mod_path = "mod.zig";

    const existing = features_dir.readFileAlloc(io, mod_path, allocator, .limited(64 * 1024)) catch "";
    defer if (existing.len > 0) allocator.free(existing);

    const new_line = try std.fmt.allocPrint(allocator, "pub const {s} = @import(\"{s}/mod.zig\");\n", .{ feature, feature });
    defer allocator.free(new_line);

    const new_content = try std.mem.concat(allocator, u8, &.{
        existing, new_line,
    });
    defer allocator.free(new_content);

    try fs_utils.writeFile(io, features_dir, mod_path, new_content);
}
