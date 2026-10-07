const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("spider_xlsx", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // Pure Zig — no C dependency, no link_libc.
        // (spider is not imported: this module depends on std only, so
        // it can be moved to its own repository unchanged.)
    });

    // Unit tests — run standalone here; Spider's own `zig build test`
    // does not compile this package (it is opt-in via -Dxlsx=true).
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run xlsx module unit tests");
    test_step.dependOn(&run_mod_tests.step);
}
