const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("mssql", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // `zig build demo`: connects with the MSSQL_* variables and prints the
    // result sets of a query (the first argument, or a tour of the types).
    const demo = b.addExecutable(.{
        .name = "mssql-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "mssql", .module = mod }},
        }),
    });
    const run_demo = b.addRunArtifact(demo);
    run_demo.addPassthruArgs();
    b.step("demo", "Run the demo against a SQL Server").dependOn(&run_demo.step);

    // Unit tests: no server needed.
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run the driver's unit tests").dependOn(&b.addRunArtifact(tests).step);
}
