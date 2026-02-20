const std = @import("std");

pub fn build(b: *std.Build) void {
    // Use x86_64_v2 CPU for compatibility with AWS t3.micro (avoids AVX-512)
    // Build with: zig build -Doptimize=ReleaseFast -Dcpu=x86_64_v2
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Note: For AWS t3.micro compatibility, use:
    //   zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu
    // This ensures no AVX2/AVX-512 instructions are used

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
        .name = "demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "spider", .module = spider_dep.module("spider") },
                .{ .name = "spider_pg", .module = spider_pg_mod },
                .{ .name = "auth", .module = b.createModule(.{ .root_source_file = b.path("src/auth.zig") }) },
            },
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the demo");
    run_step.dependOn(&run_cmd.step);

    // Test target
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "spider", .module = spider_dep.module("spider") },
            .{ .name = "spider_pg", .module = spider_pg_mod },
            .{ .name = "auth", .module = b.createModule(.{ .root_source_file = b.path("src/auth.zig") }) },
        },
    });
    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
