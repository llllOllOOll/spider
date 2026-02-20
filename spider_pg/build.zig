const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("spider_pg", .{
        .root_source_file = b.path("src/pool.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.link_libc = true;
    mod.linkSystemLibrary("pq", .{});
}
