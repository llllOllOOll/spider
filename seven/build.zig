const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Compare mode — embed vs runtime
    const exe_compare = b.addExecutable(.{
        .name = "poc_compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_compare.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe_compare);

    const run_cmd_compare = b.addRunArtifact(exe_compare);
    run_cmd_compare.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Compare embed vs runtime (default)");
    run_step.dependOn(&run_cmd_compare.step);

    // Runtime mode — zero configuração
    const exe_runtime = b.addExecutable(.{
        .name = "poc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_runtime.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe_runtime);

    const run_cmd_runtime = b.addRunArtifact(exe_runtime);
    run_cmd_runtime.step.dependOn(b.getInstallStep());

    const run_step_runtime = b.step("run_runtime", "Run Runtime Mode");
    run_step_runtime.dependOn(&run_cmd_runtime.step);

    // Embed mode — com templates embutidos
    const exe_embed = b.addExecutable(.{
        .name = "poc_embed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_embed.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe_embed);

    const run_cmd_embed = b.addRunArtifact(exe_embed);
    run_cmd_embed.step.dependOn(b.getInstallStep());

    const run_step_embed = b.step("run_embed", "Run Embed Mode");
    run_step_embed.dependOn(&run_cmd_embed.step);

    // Alternative 2 — zero configuração antigo
    const exe2 = b.addExecutable(.{
        .name = "poc2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main2.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe2);

    const run_cmd2 = b.addRunArtifact(exe2);
    run_cmd2.step.dependOn(b.getInstallStep());

    const run_step2 = b.step("run2", "Run Alternative 2 (zero config)");
    run_step2.dependOn(&run_cmd2.step);
}
