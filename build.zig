const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pacman_dep = b.dependency("pacman", .{});

    const tc_env = b.addTranslateC(.{
        .root_source_file = b.path("includes/env.h"),
        .target = target,
        .optimize = optimize,
    });
    tc_env.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    const c_env = tc_env.createModule();

    const tc_pg = b.addTranslateC(.{
        .root_source_file = b.path("includes/pg.h"),
        .target = target,
        .optimize = optimize,
    });
    tc_pg.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    const c_pg = tc_pg.createModule();

    const tc_sqlite = b.addTranslateC(.{
        .root_source_file = b.path("includes/sqlite.h"),
        .target = target,
        .optimize = optimize,
    });
    tc_sqlite.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    const c_sqlite = tc_sqlite.createModule();

    const mod = b.addModule("spider", .{
        .root_source_file = b.path("src/spider.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "pacman", .module = pacman_dep.module("pacman") },
            .{ .name = "c_env", .module = c_env },
            .{ .name = "c_pg", .module = c_pg },
            .{ .name = "c_sqlite", .module = c_sqlite },
        },
    });
    mod.linkSystemLibrary("pq", .{});
    mod.linkSystemLibrary("sqlite3", .{});

    // generate-templates — CLI tool used by dev projects
    const gen_exe = b.addExecutable(.{
        .name = "generate-templates",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/generate_templates.zig"),
            .target = target,
        }),
    });
    b.installArtifact(gen_exe);

    // spider_build — build helpers for dev projects
    _ = b.addModule("spider_build", .{
        .root_source_file = b.path("src/build_helpers.zig"),
    });

    // spider-test — test server with WebSocket (not installed)
    const test_exe = b.addExecutable(.{
        .name = "spider-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_ws_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "spider", .module = mod },
            },
        }),
    });
    // NÃO instalar — só usar para testes locais
    // b.installArtifact(test_exe);

    const run_test = b.addRunArtifact(test_exe);
    const run_step = b.step("run", "Run test server");
    run_step.dependOn(&run_test.step);

    // tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
