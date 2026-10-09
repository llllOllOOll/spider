const std = @import("std");

/// Which `std.Io` implementation `Server.listen()` constructs.
/// `.threaded` is the default: a bounded `Io.Threaded` pool
/// (`cpu_count - 1` concurrent async tasks, unlimited `.concurrent()`).
/// `.zio` is experimental: an event-driven runtime (io_uring/epoll/kqueue)
/// with no such thread-per-task ceiling for I/O-bound work — see
/// `zio_backend_test.zig` for a benchmark demonstrating the difference.
const IoBackend = enum { threaded, zio };

/// Where the templates of an app that declares `spider_templates` come from.
///
/// `.auto` (the default): read from disk (`views_dir`) in a Debug build, so
/// an edit shows on the next request with no compile and no restart, and
/// embedded in the binary in a release build, which is then all a deploy
/// needs. `.embedded` and `.disk` force one or the other in every build.
///
///     // an app's build.zig
///     const spider_dep = b.dependency("spider", .{ .optimize = optimize, .templates = .embedded });
///
/// It follows the `optimize` the app passes to the dependency: an app that
/// does not pass it builds Spider in Debug, hence from disk.
pub const Templates = enum { auto, embedded, disk };

/// For `spider.testing.expectAllTestsDiscovered`: a module listing the files
/// under `dir` (relative to the calling build root, the directory of the
/// module's root file) that declare `test "..."` blocks, with the test-name
/// prefix Zig gives each. Paths under `dir` starting with any of `exclude`
/// are skipped (e.g. subdirectories that are modules of their own).
///
/// The scan is a build step that runs on every build: done while build.zig
/// is configured it would go stale (Zig caches that phase until build.zig
/// changes), so a new test file would never be noticed.
///
///     // an app's build.zig
///     const spider_build = @import("spider");
///     const tool = spider_dep.artifact("spider-test-manifest");
///     features_mod.addImport("test_manifest", spider_build.testManifest(b, tool, "src/features", &.{}));
pub fn testManifest(b: *std.Build, tool: *std.Build.Step.Compile, dir: []const u8, exclude: []const []const u8) *std.Build.Module {
    const run = b.addRunArtifact(tool);
    run.has_side_effects = true;
    run.addDirectoryArg(b.path(dir));
    const out = run.addOutputFileArg("test_manifest.zig");
    run.addArg(dir);
    for (exclude) |e| run.addArg(e);
    return b.createModule(.{ .root_source_file = out });
}

pub const DevOptions = struct {
    /// Files, relative to the build root, that the page uses besides the
    /// binary and that a build can change (the generated stylesheet). When
    /// only these changed, `spider dev` reloads the browser without
    /// restarting the app.
    assets: []const []const u8 = &.{},
    /// The directory with the app's templates, relative to the build root.
    /// In a Debug build templates are read from disk (see `Templates`), so
    /// an edited template is not part of the binary: naming the directory
    /// here makes the edit rerun this step and count as a change of the
    /// page.
    templates: ?[]const u8 = null,
};

/// The `dev` build step `spider dev` runs (`zig build dev --watch`): builds
/// `exe` and then runs `tool`, which tells the supervisor where the new
/// binary is. Runs after every successful build, not after a failed one.
/// Outside `spider dev` the tool does nothing, so `zig build dev` is just a
/// build.
///
/// Returns the notifying step, for whatever else must be finished before
/// the browser reloads:
///
///     // an app's build.zig
///     const spider_build = @import("spider");
///     const dev = spider_build.devStep(b, spider_dep.artifact("spider-dev-notify"), exe, .{
///         .assets = &.{"public/css/app.css"},
///     });
///     dev.step.dependOn(&css.step);
pub fn devStep(b: *std.Build, tool: *std.Build.Step.Compile, exe: *std.Build.Step.Compile, options: DevOptions) *std.Build.Step.Run {
    const run = b.addRunArtifact(tool);
    // Not cached: when `spider dev` starts on an up-to-date project nothing
    // is rebuilt, and it still needs to be told where the binary is. (Nor
    // could Zig's cache be trusted with it: the incremental linker rewrites
    // the binary without changing its size or modification time.)
    run.has_side_effects = true;
    run.addArtifactArg(exe);
    for (options.assets) |asset| run.addArg(asset);
    if (options.templates) |dir| {
        run.addArg(b.fmt("--templates={s}", .{dir}));
        watchSources(b, run, dir, &.{ ".html", ".md" });
    }
    run.setCwd(b.path("."));
    const step = b.step("dev", "Build the app for `spider dev`");
    step.dependOn(&run.step);
    return run;
}

/// Declares every file under `dir` (relative to the build root, searched
/// recursively) whose name ends with one of `extensions` as an input of
/// `run`: `zig build --watch` then reruns the step when one of them changes,
/// and skips it when none did. New, removed and renamed files are noticed
/// too (the build script is configured again).
///
///     // Tailwind reads the stylesheets and looks for class names everywhere
///     spider_build.watchSources(b, css, "src", &.{ ".css", ".html", ".js" });
pub fn watchSources(b: *std.Build, run: *std.Build.Step.Run, dir: []const u8, extensions: []const []const u8) void {
    const io = b.graph.io;
    const arena = b.graph.arena;
    b.dependOnDirectoryContents(b.path(dir));
    var root = b.root.openDir(io, dir, .{ .iterate = true }) catch return;
    defer root.close(io);
    var walker = root.walk(arena) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        const sub_path = std.fs.path.join(arena, &.{ dir, entry.path }) catch @panic("OOM");
        switch (entry.kind) {
            .directory => b.dependOnDirectoryContents(b.path(sub_path)),
            .file => for (extensions) |ext| {
                if (std.mem.endsWith(u8, entry.basename, ext)) {
                    run.addFileInput(b.path(sub_path));
                    break;
                }
            },
            else => {},
        }
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const with_pg = b.option(bool, "pg", "Enable PostgreSQL support") orelse false;
    const with_r2 = b.option(bool, "r2", "Enable Cloudflare R2 support") orelse false;
    const with_sqlite = b.option(bool, "sqlite", "Enable SQLite support") orelse false;
    const with_qrcode = b.option(bool, "qrcode", "Enable QR code generation") orelse false;
    const with_xlsx = b.option(bool, "xlsx", "Enable Excel .xlsx export") orelse false;
    const io_backend = b.option(
        IoBackend,
        "io_backend",
        "I/O backend for Server.listen(): threaded (default, stable) or zio (experimental, event-driven)",
    ) orelse .threaded;

    const build_options = b.addOptions();
    build_options.addOption(IoBackend, "io_backend", io_backend);
    const templates = b.option(
        Templates,
        "templates",
        "Where an app's templates come from: auto (default: disk in a Debug build, embedded in a release build), embedded, disk",
    ) orelse .auto;
    build_options.addOption(bool, "templates_from_disk", switch (templates) {
        .auto => optimize == .debug,
        .embedded => false,
        .disk => true,
    });
    const build_options_mod = build_options.createModule();

    const pacman_dep = b.dependency("pacman", .{});
    const pg_dep = b.dependency("pg", .{ .target = target, .optimize = optimize });
    const zqlite_dep = b.dependency("zqlite", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("spider", .{
        .root_source_file = b.path("src/spider.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "pacman", .module = pacman_dep.module("pacman") },
            .{ .name = "pg", .module = pg_dep.module("pg") },
            .{ .name = "spider_build_options", .module = build_options_mod },
        },
    });

    if (io_backend == .zio) {
        // zio is a lazy dependency (see build.zig.zon). b.dependency() on
        // one that is not fetched yet ends this configure pass; Zig fetches
        // it and configures again, within the same `zig build`.
        //
        // Forces epoll instead of zio's own Linux default (io_uring):
        // io_uring_setup() came back EPERM under Docker's default seccomp
        // profile (io_uring syscalls aren't in its allowlist — a
        // well-known restriction, io_uring has a heavy CVE history).
        // Confirmed via a minimal zio-only reproduction (github.com/
        // llllOllOOll/spider tree, see zio_app scratch project) deployed
        // to the same VPS/Docker setup as production: crashed within
        // seconds with io_uring (default), ran clean with
        // -Dbackend=epoll forced. epoll is supported by every Linux
        // seccomp profile in practice, at the cost of io_uring's lower
        // per-syscall overhead — not a concern at this app's scale.
        const zio_dep = b.dependency("zio", .{
            .target = target,
            .optimize = optimize,
            .backend = @as(?[]const u8, "epoll"),
        });
        mod.addImport("zio", zio_dep.module("zio"));
    }

    if (with_pg) {
        const pg_module_dep = b.lazyDependency("spider_pg", .{
            .target = target,
            .optimize = optimize,
        }) orelse unreachable;
        const spider_pg = pg_module_dep.module("spider_pg");
        spider_pg.addImport("spider", mod);
        mod.addImport("spider_pg", spider_pg);
    }

    if (with_sqlite) {
        if (b.lazyDependency("spider_sqlite", .{ .target = target, .optimize = optimize })) |dep| {
            const spider_sqlite = dep.module("spider_sqlite");
            spider_sqlite.addImport("spider", mod);
            mod.addImport("spider_sqlite", spider_sqlite);
        }
    }

    if (with_r2) {
        if (b.lazyDependency("spider_r2", .{ .target = target, .optimize = optimize })) |dep| {
            const spider_r2 = dep.module("spider_r2");
            spider_r2.addImport("spider", mod);
            spider_r2.addImport("pacman", pacman_dep.module("pacman"));
            mod.addImport("spider_r2", spider_r2);
        }
    }

    if (with_qrcode) {
        // Unlike pg/r2/sqlite, this module has no dependency on
        // spider's own Ctx/Response types (it only produces a module
        // matrix), so it does not need `spider_qrcode.addImport("spider", mod)`.
        if (b.lazyDependency("spider_qrcode", .{ .target = target, .optimize = optimize })) |dep| {
            const spider_qrcode = dep.module("spider_qrcode");
            mod.addImport("spider_qrcode", spider_qrcode);
        }
    }

    if (with_xlsx) {
        // Same as qrcode: std only, no dependency on spider's types.
        if (b.lazyDependency("spider_xlsx", .{ .target = target, .optimize = optimize })) |dep| {
            const spider_xlsx = dep.module("spider_xlsx");
            mod.addImport("spider_xlsx", spider_xlsx);
        }
    }

    // Default spider_config fallback for projects without spider.config.zig
    const default_cfg = b.addWriteFiles();
    const default_cfg_file = default_cfg.add("spider_config.zig",
        \\const spider = @import("spider");
        \\pub const is_default = true;
        \\pub const config = spider.Config{};
    );
    const default_cfg_mod = b.createModule(.{
        .root_source_file = default_cfg_file,
        .imports = &.{
            .{ .name = "spider", .module = mod },
        },
    });
    mod.addImport("spider_config", default_cfg_mod);

    // Default template_helpers fallback for projects without their own
    // helpers module. Apps override this by calling mod.addImport with a
    // real template_helpers.zig — see render/renderer.zig's .call case.
    const default_helpers = b.addWriteFiles();
    const default_helpers_file = default_helpers.add("template_helpers.zig",
        \\// No custom template helpers registered — any { name(...) } call in
        \\// a template renders empty (see render/renderer.zig's .call case).
    );
    const default_helpers_mod = b.createModule(.{
        .root_source_file = default_helpers_file,
    });
    mod.addImport("template_helpers", default_helpers_mod);

    // spider CLI — `spider new <app_name>`
    const cli_exe = b.addExecutable(.{
        .name = "spider",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "pg", .module = pg_dep.module("pg") },
                .{ .name = "zqlite", .module = zqlite_dep.module("zqlite") },
            },
        }),
    });
    b.installArtifact(cli_exe);

    // generate-templates — CLI tool used by dev projects
    const gen_exe = b.addExecutable(.{
        .name = "generate-templates",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/generate_templates.zig"),
            .target = target,
        }),
    });
    b.installArtifact(gen_exe);

    // spider-dev-notify — build tool behind devStep(), for `spider dev`.
    const dev_notify_tool = b.addExecutable(.{
        .name = "spider-dev-notify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dev_notify_tool.zig"),
            .target = b.graph.host,
        }),
    });
    b.installArtifact(dev_notify_tool); // apps: spider_dep.artifact("spider-dev-notify")

    // tests — existing module tests. test_manifest lets the discovery test
    // in src/spider.zig fail when a file's tests aren't part of this binary.
    const manifest_tool = b.addExecutable(.{
        .name = "spider-test-manifest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_manifest_tool.zig"),
            .target = b.graph.host,
        }),
    });
    b.installArtifact(manifest_tool); // apps: spider_dep.artifact("spider-test-manifest")
    mod.addImport("test_manifest", testManifest(b, manifest_tool, "src", &.{"cli/"}));
    cli_exe.root_module.addImport("test_manifest", testManifest(b, manifest_tool, "src/cli", &.{"templates/"}));
    cli_exe.root_module.addImport("spider_testing", b.createModule(.{ .root_source_file = b.path("src/testing.zig") }));
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    // CLI argument handling (src/cli/args.zig, via src/cli/main.zig's test block).
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = cli_exe.root_module })).step);

    // spider.xlsx is opt-in. Without -Dxlsx=true the module is not part
    // of the build at all, and that is checked here: the probe, which
    // only touches spider.xlsx, must fail to compile for lack of the
    // module. With -Dxlsx=true the same probe runs as a test.
    const xlsx_probe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("xlsx_optional_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "spider", .module = mod }},
        }),
    });
    if (with_xlsx) {
        test_step.dependOn(&b.addRunArtifact(xlsx_probe).step);
    } else {
        xlsx_probe.expect_errors = .{ .contains = "no module named 'spider_xlsx' available within module 'spider'" };
        test_step.dependOn(&xlsx_probe.step);
    }

    // test-zio-backend — integration test for the zio io_backend: starts a
    // real Server.listen() and hits it with real concurrent HTTP requests.
    // Only exists when `-Dio_backend=zio` is passed, since it can't build
    // against a `mod` that doesn't have `zio` wired in. Has side effects
    // (binds a TCP listener), so it's a separate step from `test`.
    if (io_backend == .zio) {
        const zio_backend_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("zio_backend_test.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "spider", .module = mod },
                    .{ .name = "pacman", .module = pacman_dep.module("pacman") },
                },
            }),
        });
        const run_zio_backend_test = b.addRunArtifact(zio_backend_test);
        run_zio_backend_test.has_side_effects = true;
        const test_zio_backend_step = b.step("test-zio-backend", "Run zio io_backend integration test (requires -Dio_backend=zio)");
        test_zio_backend_step.dependOn(&run_zio_backend_test.step);
    }

    // test-e2e — real-socket tests against Server.listen() (threaded
    // backend). Has side effects (binds TCP listeners), so it's a separate
    // step from `test`.
    const e2e_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("e2e_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "spider", .module = mod },
            },
        }),
    });
    const run_e2e_test = b.addRunArtifact(e2e_test);
    run_e2e_test.has_side_effects = true;
    const test_e2e_step = b.step("test-e2e", "Run end-to-end tests against a real listening Server");
    test_e2e_step.dependOn(&run_e2e_test.step);

    // test-pacman — the HTTP client's own tests (modules/pacman). Most of
    // them call httpbingo.org, so they need network access.
    const pacman_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("modules/pacman/src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_pacman_test = b.addRunArtifact(pacman_test);
    run_pacman_test.has_side_effects = true;
    const test_pacman_step = b.step("test-pacman", "Run the HTTP client tests (needs network access)");
    test_pacman_step.dependOn(&run_pacman_test.step);

    // test-pacman-local — the HTTP client against scripted local servers
    // (timeouts, cut bodies, oversized responses). No network needed. Runs
    // on the backend chosen with -Dio_backend: threaded by default, zio
    // with -Dio_backend=zio (the one production uses).
    {
        const local_opts = b.addOptions();
        local_opts.addOption(bool, "zio", io_backend == .zio);
        const local_mod = b.createModule(.{
            .root_source_file = b.path("modules/pacman/local_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "pacman", .module = pacman_dep.module("pacman") },
            },
        });
        local_mod.addOptions("local_test_options", local_opts);
        if (io_backend == .zio) {
            const zio_local_dep = b.dependency("zio", .{
                .target = target,
                .optimize = optimize,
                .backend = @as(?[]const u8, "epoll"),
            });
            local_mod.addImport("zio", zio_local_dep.module("zio"));
        }
        const pacman_local_test = b.addTest(.{ .root_module = local_mod });
        const run_pacman_local_test = b.addRunArtifact(pacman_local_test);
        run_pacman_local_test.has_side_effects = true;
        const test_pacman_local_step = b.step("test-pacman-local", "Run the HTTP client tests against scripted local servers (no network)");
        test_pacman_local_step.dependOn(&run_pacman_local_test.step);
    }

    // test-pg — pg wrapper integration tests (requires PostgreSQL)
    const pg_lib_mod = pg_dep.module("pg");

    const spider_core_mod = b.createModule(.{
        .root_source_file = b.path("src/spider_core_for_pg.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const pg_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("pg_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "pg", .module = pg_lib_mod },
                .{ .name = "spider", .module = spider_core_mod },
            },
        }),
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    const run_pg_tests = b.addRunArtifact(pg_test);
    run_pg_tests.has_side_effects = true;
    const test_pg_step = b.step("test-pg", "Run pg wrapper integration tests");
    test_pg_step.dependOn(&run_pg_tests.step);

    // test-sqlite — sqlite wrapper tests (uses :memory:, no external DB needed)
    const zqlite_mod = zqlite_dep.module("zqlite");

    const sqlite_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("modules/sqlite/src/sqlite.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zqlite", .module = zqlite_mod },
                // sqlite.zig reads its settings through spider.env; the
                // tests get a stub that answers every key with its default.
                .{ .name = "spider", .module = b.createModule(.{
                    .root_source_file = b.path("modules/sqlite/src/test_env_stub.zig"),
                }) },
            },
        }),
    });
    const run_sqlite_tests = b.addRunArtifact(sqlite_test);
    const test_sqlite_step = b.step("test-sqlite", "Run sqlite tests");
    test_sqlite_step.dependOn(&run_sqlite_tests.step);

    // test-xlsx — the xlsx module's own unit tests (std only). They are
    // not part of `test`: the default build does not compile the module.
    const xlsx_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("modules/xlsx/src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_xlsx_step = b.step("test-xlsx", "Run xlsx module tests");
    test_xlsx_step.dependOn(&b.addRunArtifact(xlsx_test).step);
}
