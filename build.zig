const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const curl_dep = b.dependency("curl", .{
        .target = target,
        .sanitize_c = .off,
    });

    const mod = b.addModule("spider", .{
        .root_source_file = b.path("src/spider.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "curl", .module = curl_dep.module("curl") },
        },
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
