const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const spider_dep = b.dependency("spider", .{
        .target = target,
        .optimize = optimize,
    });

    const spider_pg_dep = b.dependency("spider_pg", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "spider", .module = spider_dep.module("spider") },
                .{ .name = "spider_pg", .module = spider_pg_dep.module("spider_pg") },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run hexagonal");
    run_step.dependOn(&run_cmd.step);
}
