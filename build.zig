const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const curl_dep = b.dependency("curl", .{
        .target = target,
        .sanitize_c = .off,
    });

    const tc_env = b.addTranslateC(.{
        .root_source_file = b.path("includes/env.h"),
        .target = target,
        .optimize = optimize,
    });
    const c_env = tc_env.createModule();

    const tc_pg = b.addTranslateC(.{
        .root_source_file = b.path("includes/pg.h"),
        .target = target,
        .optimize = optimize,
    });
    const c_pg = tc_pg.createModule();

    const mod = b.addModule("spider", .{
        .root_source_file = b.path("src/spider.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "curl", .module = curl_dep.module("curl") },
            .{ .name = "c_env", .module = c_env },
            .{ .name = "c_pg", .module = c_pg },
        },
    });
    mod.linkSystemLibrary("pq", .{});

    _ = b.addModule("templates", .{
        .root_source_file = b.path("src/templates_stub.zig"),
    });

    const gen_exe = b.addExecutable(.{
        .name = "generate-templates",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/generate_templates.zig"),
            .target = target,
        }),
    });
    b.installArtifact(gen_exe);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
