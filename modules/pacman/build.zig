const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("pacman", .{
        .root_source_file = b.path("src/root.zig"),
    });
}
