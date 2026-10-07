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

    // test-libreoffice — writes a sample workbook, has headless
    // LibreOffice convert it to CSV and compares the cells (see
    // libreoffice_check.zig), proving the file opens in a real,
    // independent spreadsheet program. Separate
    // from the default `test` step (same pattern as qrcode's
    // test-decode) since it shells out to a tool that may not be
    // installed everywhere.
    const check_exe = b.addExecutable(.{
        .name = "libreoffice_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("libreoffice_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "xlsx", .module = mod }},
        }),
    });

    const check_run = b.addRunArtifact(check_exe);
    _ = check_run.addOutputDirectoryArg("work");
    // Cells are compared "as shown": pin the language LibreOffice uses
    // for words such as TRUE.
    check_run.setEnvironmentVariable("LC_ALL", "en_US.UTF-8");
    check_run.expectExitCode(0);

    const test_libreoffice_step = b.step("test-libreoffice", "Open a generated workbook with headless LibreOffice and compare the cells (requires soffice installed)");
    test_libreoffice_step.dependOn(&check_run.step);

    // sample-files — writes the workbooks used for checks by hand in
    // Excel, Google Sheets and Numbers (see sample_files.zig) to
    // zig-out/sample-files.
    const samples_exe = b.addExecutable(.{
        .name = "sample_files",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sample_files.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "xlsx", .module = mod }},
        }),
    });
    const samples_run = b.addRunArtifact(samples_exe);
    const samples_dir = samples_run.addOutputDirectoryArg("sample-files");
    const install_samples = b.addInstallDirectory(.{
        .source_dir = samples_dir,
        .install_dir = .prefix,
        .install_subdir = "sample-files",
    });
    const sample_files_step = b.step("sample-files", "Write sample workbooks to zig-out/sample-files, for checks by hand in Excel and Google Sheets");
    sample_files_step.dependOn(&install_samples.step);
}
