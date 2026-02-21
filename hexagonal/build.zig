const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const spider_dep = b.dependency("spider", .{
        .target = target,
        .optimize = optimize,
    });

    const spider_pg_mod = b.createModule(.{
        .root_source_file = b.path("../spider_pg/src/pool.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    spider_pg_mod.linkSystemLibrary("pq", .{});

    const exe = b.addExecutable(.{
        .name = "hexagonal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "spider", .module = spider_dep.module("spider") },
                .{ .name = "spider_pg", .module = spider_pg_mod },
                .{ .name = "repository", .module = b.createModule(.{ .root_source_file = b.path("repository.zig") }) },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run hexagonal");
    run_step.dependOn(&run_cmd.step);
}
