const std = @import("std");

// Embedded templates
const build_zig_tmpl = @embedFile("templates/build.zig.template");
const build_zon_tmpl = @embedFile("templates/build.zig.zon.template");
const spider_config_tmpl = @embedFile("templates/spider.config.zig.template");
const main_zig_tmpl = @embedFile("templates/main.zig.template");
const layout_html_tmpl = @embedFile("templates/layout.html.template");
const home_index_tmpl = @embedFile("templates/home_index.html.template");
const home_controller_tmpl = @embedFile("templates/home_controller.zig.template");
const dockerfile_tmpl = @embedFile("templates/Dockerfile.template");
const docker_compose_tmpl = @embedFile("templates/docker-compose.yml.template");
const env_example_tmpl = @embedFile("templates/.env.example.template");
const env_example_pg_tmpl = @embedFile("templates/.env.example.pg.template");
const gitignore_tmpl = @embedFile("templates/.gitignore.template");
const core_mod_tmpl = @embedFile("templates/core_mod.zig.template");
const features_mod_tmpl = @embedFile("templates/features_mod.zig.template");
const features_mod_api_tmpl = @embedFile("templates/features_mod.zig.api.template");
const home_mod_tmpl = @embedFile("templates/home_mod.zig.template");
const home_routes_tmpl = @embedFile("templates/home_routes.zig.template");
const styles_css_tmpl = @embedFile("templates/styles.css.template");
const nav_bar_tmpl = @embedFile("templates/nav-bar.html.template");
const side_bar_tmpl = @embedFile("templates/side-bar.html.template");
const mobile_nav_tmpl = @embedFile("templates/mobile-nav.html.template");
const toast_tmpl = @embedFile("templates/toast.html.template");
const stores_js_tmpl = @embedFile("templates/stores.js.template");
const spider_logo_png = @embedFile("assets/spider_logo.png");
const favicon_png = @embedFile("assets/favicon.png");
const favicon_ico = @embedFile("assets/favicon.ico");
const layout_daisyui_html_tmpl = @embedFile("templates/layout_daisyui.html.template");
const home_daisyui_index_tmpl = @embedFile("templates/home_daisyui_index.html.template");
const build_zig_pg_tmpl = @embedFile("templates/build.zig.pg.template");
const build_zig_sqlite_tmpl = @embedFile("templates/build.zig.sqlite.template");
const main_zig_pg_tmpl = @embedFile("templates/main.zig.pg.template");
const main_zig_sqlite_tmpl = @embedFile("templates/main.zig.sqlite.template");
const main_zig_api_tmpl = @embedFile("templates/main.zig.api.template");
const main_zig_api_sqlite_tmpl = @embedFile("templates/main.zig.api.sqlite.template");
const build_zig_api_tmpl = @embedFile("templates/build.zig.api.template");
const migrations_zig_sqlite_tmpl = @embedFile("templates/migrations.zig.sqlite.template");
const migrations_zig_pg_tmpl = @embedFile("templates/migrations.zig.pg.template");
const agents_md_tmpl = @embedFile("templates/AGENTS.md.template");
const agents_views_html_tmpl = @embedFile("templates/agents_views_html.md.template");
const agents_views_api_tmpl = @embedFile("templates/agents_views_api.md.template");
const agents_views_conv_html_tmpl = @embedFile("templates/agents_views_conv_html.md.template");
const agents_views_conv_api_tmpl = @embedFile("templates/agents_views_conv_api.md.template");
const agents_db_sqlite_tmpl = @embedFile("templates/agents_db_sqlite.md.template");
const agents_db_pg_tmpl = @embedFile("templates/agents_db_pg.md.template");
const agents_db_none_tmpl = @embedFile("templates/agents_db_none.md.template");

fn runZigFetch(io: std.Io, app_name: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "zig", "fetch", "--save=spider", "git+https://github.com/llllOllOOll/spider#main" },
        .cwd = .{ .path = app_name },
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.ZigFetchFailed,
        else => return error.ZigFetchFailed,
    }
}

fn runZigInit(io: std.Io, app_name: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "zig", "init", "-m" },
        .cwd = .{ .path = app_name },
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.ZigInitFailed,
        else => return error.ZigInitFailed,
    }
}

fn extractFingerprint(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    const prefix = ".fingerprint = ";
    const idx = std.mem.indexOf(u8, content, prefix) orelse return error.FingerprintNotFound;
    const rest = content[idx + prefix.len ..];
    const end = std.mem.indexOfAny(u8, rest, ",\n") orelse rest.len;
    return allocator.dupe(u8, std.mem.trim(u8, rest[0..end], " "));
}

fn readFingerprint(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir) ![]const u8 {
    const file = try dir.openFile(io, "build.zig.zon", .{});
    defer file.close(io);
    var buf: [256]u8 = undefined;
    var reader: std.Io.File.Reader = .init(file, io, &buf);
    const content = try reader.interface.allocRemaining(allocator, .limited(8192));
    defer allocator.free(content);
    return extractFingerprint(allocator, content);
}

fn toZonSafe(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const result = try allocator.dupe(u8, name);
    for (result) |*c| {
        switch (c.*) {
            '-', ' ', '.' => c.* = '_',
            else => {},
        }
    }
    return result;
}

fn render(allocator: std.mem.Allocator, tmpl: []const u8, app_name: []const u8, zon_name: []const u8, fingerprint: []const u8, db_module: []const u8, sqlite_enabled: []const u8) ![]const u8 {
    const step1 = try std.mem.replaceOwned(u8, allocator, tmpl, "{{app_name}}", app_name);
    defer allocator.free(step1);
    const step2 = try std.mem.replaceOwned(u8, allocator, step1, "{{zon_name}}", zon_name);
    defer allocator.free(step2);
    const step3 = try std.mem.replaceOwned(u8, allocator, step2, "{{fingerprint}}", fingerprint);
    defer allocator.free(step3);
    const step4 = try std.mem.replaceOwned(u8, allocator, step3, "{{db_module}}", db_module);
    defer allocator.free(step4);
    return std.mem.replaceOwned(u8, allocator, step4, "{{sqlite_enabled}}", sqlite_enabled);
}

/// AGENTS.md for the new project: the shared template plus the sections that
/// depend on the variant (views or API-only; SQLite, PostgreSQL or no db).
fn renderAgentsMd(allocator: std.mem.Allocator, app_name: []const u8, api_only: bool, no_db: bool, use_pg: bool) ![]const u8 {
    const variant = try std.fmt.allocPrint(allocator, "{s}, {s}", .{
        if (api_only) "API-only" else "HTML views",
        if (no_db) "no database" else if (use_pg) "PostgreSQL" else "SQLite",
    });
    defer allocator.free(variant);
    const vars = [_][2][]const u8{
        .{ "{{app_name}}", app_name },
        .{ "{{variant}}", variant },
        .{ "{{feature_api_flag}}", if (api_only) " --api" else "" },
        .{ "{{extra_commands}}", if (!no_db and use_pg) "| First-time setup | `docker compose up -d db` |\n" else "" },
        .{ "{{core_db_line}}", if (no_db) "" else "\n  db/migrations.zig       migration list (+ SQL files in db/migrations/)" },
        .{ "{{views_layout}}", if (api_only) agents_views_api_tmpl else agents_views_html_tmpl },
        .{ "{{views_conventions}}", if (api_only) agents_views_conv_api_tmpl else agents_views_conv_html_tmpl },
        .{ "{{db_section}}", if (no_db) agents_db_none_tmpl else if (use_pg) agents_db_pg_tmpl else agents_db_sqlite_tmpl },
    };
    var out = try allocator.dupe(u8, agents_md_tmpl);
    for (vars) |v| {
        const next = try std.mem.replaceOwned(u8, allocator, out, v[0], v[1]);
        allocator.free(out);
        out = next;
    }
    return out;
}

/// The generated .env: `.env.example` with the JWT_SECRET placeholder
/// replaced by `secret`.
pub fn envFromExample(allocator: std.mem.Allocator, example: []const u8, secret: []const u8) ![]u8 {
    const placeholder = "JWT_SECRET=change_me_in_production";
    const line = try std.fmt.allocPrint(allocator, "JWT_SECRET={s}", .{secret});
    defer allocator.free(line);
    return std.mem.replaceOwned(u8, allocator, example, placeholder, line);
}

test "envFromExample: the example's settings with a generated JWT_SECRET" {
    const a = std.testing.allocator;
    inline for (.{ env_example_tmpl, env_example_pg_tmpl }) |tmpl| {
        const out = try envFromExample(a, tmpl, "0123abcd");
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "\nJWT_SECRET=0123abcd\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "change_me") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "PG_HOST=localhost") != null);
    }
}

test "the generated .gitignore keeps .env out of git" {
    try std.testing.expect(std.mem.indexOf(u8, gitignore_tmpl, "\n.env\n") != null);
}

fn writeFile(io: std.Io, dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        dir.createDirPath(io, parent) catch {};
    }
    const file = try dir.createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer: std.Io.File.Writer = .init(file, io, &buf);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, app_name: []const u8, use_daisyui: bool, skip_downloads: bool, api_only: bool, no_db: bool, use_pg: bool) !void {
    // check zig is available
    const zig_result = std.process.run(allocator, io, .{
        .argv = &.{ "zig", "version" },
    }) catch {
        std.debug.print("error: 'zig' command not found\n", .{});
        std.debug.print("Spider requires Zig 0.17.0-dev or later.\n", .{});
        std.debug.print("Download at: https://ziglang.org/download/\n", .{});
        return error.ZigNotFound;
    };
    defer allocator.free(zig_result.stdout);
    defer allocator.free(zig_result.stderr);

    switch (zig_result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("error: 'zig version' returned exit code {d}\n", .{code});
            return error.ZigNotFound;
        },
        else => {
            std.debug.print("error: 'zig version' terminated abnormally\n", .{});
            return error.ZigNotFound;
        },
    }

    const zig_version = std.mem.trim(u8, zig_result.stdout, " \n\r\t");
    std.debug.print("Using Zig: {s}\n", .{zig_version});

    // --api skips frontend assets; --api does not force no-db
    const effective_no_db = no_db;
    const effective_skip = skip_downloads or api_only;

    const cwd = std.Io.Dir.cwd();

    cwd.createDir(io, app_name, .default_dir) catch |err| {
        if (err == error.PathAlreadyExists) {
            std.debug.print("error: directory '{s}' already exists\n", .{app_name});
            return error.DirExists;
        }
        return err;
    };

    // Registered first → runs second (after error is logged)
    errdefer {
        std.debug.print("  Cleaning up {s}/...\n", .{app_name});
        cwd.deleteTree(io, app_name) catch {};
    }

    // Registered second → runs first (LIFO), prints before cleanup
    var current_step: []const u8 = "unknown";
    var fail_err: anyerror = error.Unknown;
    errdefer std.debug.print("error: failed at step '{s}' — {s}\n", .{ current_step, @errorName(fail_err) });

    current_step = "zig init";
    runZigInit(io, app_name) catch |err| {
        fail_err = err;
        return err;
    };

    var project_dir = cwd.openDir(io, app_name, .{}) catch |err| {
        fail_err = err;
        return err;
    };
    defer project_dir.close(io);

    project_dir.createDirPath(io, "bin") catch {};
    project_dir.createDirPath(io, "public/js") catch {};
    project_dir.createDirPath(io, "public/css") catch {};
    project_dir.createDirPath(io, "public/fonts") catch {};

    if (!effective_skip) {
        std.debug.print("  Run 'spider install' to download frontend assets\n", .{});
    }

    current_step = "read fingerprint";
    const fingerprint = readFingerprint(io, allocator, project_dir) catch |err| {
        fail_err = err;
        return err;
    };
    defer allocator.free(fingerprint);

    const zon_safe_name = try toZonSafe(allocator, app_name);
    defer allocator.free(zon_safe_name);

    std.debug.print("Creating {s}...\n", .{app_name});

    const selected_layout_tmpl = if (use_daisyui) layout_daisyui_html_tmpl else layout_html_tmpl;
    const selected_home_index_tmpl = if (use_daisyui) home_daisyui_index_tmpl else home_index_tmpl;
    const selected_build_zig_tmpl = if (api_only) build_zig_api_tmpl else if (effective_no_db) build_zig_tmpl else if (use_pg) build_zig_pg_tmpl else build_zig_sqlite_tmpl;
    const selected_main_zig_tmpl = if (api_only and effective_no_db) main_zig_api_tmpl else if (api_only) main_zig_api_sqlite_tmpl else if (effective_no_db) main_zig_tmpl else if (use_pg) main_zig_pg_tmpl else main_zig_sqlite_tmpl;
    const selected_env_example_tmpl = if (effective_no_db or !use_pg) env_example_tmpl else env_example_pg_tmpl;

    // For API projects, use sqlite_enabled flag in build.zig.api.template
    const sqlite_enabled = if (api_only and !no_db) "true" else "false";

    const files = .{
        .{ "build.zig", selected_build_zig_tmpl },
        .{ "build.zig.zon", build_zon_tmpl },
        .{ "spider.config.zig", spider_config_tmpl },
        .{ "src/main.zig", selected_main_zig_tmpl },
        .{ "src/styles.css", styles_css_tmpl },
        .{ "src/embedded_templates.zig", "// Generated file - DO NOT EDIT MANUALLY\npub const EmbeddedTemplates = struct {};\n" },
        .{ "src/core/mod.zig", core_mod_tmpl },
        .{ "src/features/mod.zig", features_mod_tmpl },
        .{ "src/features/home/mod.zig", home_mod_tmpl },
        .{ "src/shared/templates/layout.html", selected_layout_tmpl },
        .{ "src/shared/templates/nav-bar.html", nav_bar_tmpl },
        .{ "src/shared/templates/side-bar.html", side_bar_tmpl },
        .{ "src/shared/templates/mobile-nav.html", mobile_nav_tmpl },
        .{ "src/shared/templates/toast.html", toast_tmpl },
        .{ "public/js/stores.js", stores_js_tmpl },
        .{ "src/features/home/views/index.html", selected_home_index_tmpl },
        .{ "src/features/home/controller.zig", home_controller_tmpl },
        .{ "src/features/home/routes.zig", home_routes_tmpl },
        .{ "Dockerfile", dockerfile_tmpl },
        .{ "docker-compose.yml", docker_compose_tmpl },
        .{ ".env.example", selected_env_example_tmpl },
        .{ ".gitignore", gitignore_tmpl },
    };

    const static_assets = .{
        .{ "public/images/logo.png", spider_logo_png },
        .{ "public/favicon.png", favicon_png },
        .{ "public/favicon.ico", favicon_ico },
    };

    current_step = "write files";
    if (api_only) {
        const api_files = .{
            .{ "build.zig", selected_build_zig_tmpl },
            .{ "build.zig.zon", build_zon_tmpl },
            .{ "spider.config.zig", spider_config_tmpl },
            .{ "src/main.zig", selected_main_zig_tmpl },
            .{ "src/core/mod.zig", core_mod_tmpl },
            .{ "src/features/mod.zig", features_mod_api_tmpl },
            .{ "Dockerfile", dockerfile_tmpl },
            .{ "docker-compose.yml", docker_compose_tmpl },
            .{ ".env.example", selected_env_example_tmpl },
            .{ ".gitignore", gitignore_tmpl },
        };
        inline for (api_files) |f| {
            const path = f[0];
            const tmpl = f[1];
            const content = render(allocator, tmpl, app_name, zon_safe_name, fingerprint, "", sqlite_enabled) catch |err| {
                fail_err = err;
                return err;
            };
            defer allocator.free(content);
            writeFile(io, project_dir, path, content) catch |err| {
                fail_err = err;
                return err;
            };
            std.debug.print("  create  {s}/{s}\n", .{ app_name, path });
        }
    } else {
        inline for (files) |f| {
            const path = f[0];
            const tmpl = f[1];
            const content = render(allocator, tmpl, app_name, zon_safe_name, fingerprint, "", sqlite_enabled) catch |err| {
                fail_err = err;
                return err;
            };
            defer allocator.free(content);
            writeFile(io, project_dir, path, content) catch |err| {
                fail_err = err;
                return err;
            };
            std.debug.print("  create  {s}/{s}\n", .{ app_name, path });
        }
    }

    {
        // .env ready to use: the same settings as .env.example (which is the
        // one to commit; .gitignore ignores .env) with its own random
        // JWT_SECRET. Without it `spider migrate` found no database until
        // the developer copied the file by hand.
        const example = render(allocator, selected_env_example_tmpl, app_name, zon_safe_name, fingerprint, "", sqlite_enabled) catch |err| {
            fail_err = err;
            return err;
        };
        defer allocator.free(example);
        var secret: [32]u8 = undefined;
        std.Io.random(io, &secret);
        const hex = std.fmt.bytesToHex(secret, .lower);
        const env_content = envFromExample(allocator, example, &hex) catch |err| {
            fail_err = err;
            return err;
        };
        defer allocator.free(env_content);
        writeFile(io, project_dir, ".env", env_content) catch |err| {
            fail_err = err;
            return err;
        };
        std.debug.print("  create  {s}/.env (local settings, git-ignored; JWT_SECRET generated)\n", .{app_name});
    }

    {
        // Guide for coding agents; CLAUDE.md just imports it (Claude Code reads CLAUDE.md).
        const agents_md = renderAgentsMd(allocator, app_name, api_only, effective_no_db, use_pg) catch |err| {
            fail_err = err;
            return err;
        };
        defer allocator.free(agents_md);
        inline for (.{ .{ "AGENTS.md", agents_md }, .{ "CLAUDE.md", "@AGENTS.md\n" } }) |f| {
            writeFile(io, project_dir, f[0], f[1]) catch |err| {
                fail_err = err;
                return err;
            };
            std.debug.print("  create  {s}/{s}\n", .{ app_name, f[0] });
        }
    }

    if (!api_only) {
        inline for (static_assets) |f| {
            const path = f[0];
            const content = f[1];
            writeFile(io, project_dir, path, content) catch |err| {
                fail_err = err;
                return err;
            };
            std.debug.print("  create  {s}/{s}\n", .{ app_name, path });
        }
    }

    if (!effective_no_db) {
        const db_module = if (use_pg) "pg" else "sqlite";
        const selected_migrations_tmpl = if (use_pg) migrations_zig_pg_tmpl else migrations_zig_sqlite_tmpl;
        const migrations_content = render(allocator, selected_migrations_tmpl, app_name, zon_safe_name, fingerprint, db_module, sqlite_enabled) catch |err| {
            fail_err = err;
            return err;
        };
        defer allocator.free(migrations_content);
        writeFile(io, project_dir, "src/core/db/migrations.zig", migrations_content) catch |err| {
            fail_err = err;
            return err;
        };
        std.debug.print("  create  {s}/src/core/db/migrations.zig\n", .{app_name});

        // wire db/mod.zig into the module tree
        writeFile(io, project_dir, "src/core/db/mod.zig", "pub const migrations = @import(\"migrations.zig\");\n") catch |err| {
            fail_err = err;
            return err;
        };
        std.debug.print("  create  {s}/src/core/db/mod.zig\n", .{app_name});

        {
            const core_mod_content = try project_dir.readFileAlloc(io, "src/core/mod.zig", allocator, .limited(4096));
            defer allocator.free(core_mod_content);
            if (std.mem.indexOf(u8, core_mod_content, "pub const db") == null) {
                const updated = try std.mem.concat(allocator, u8, &.{ core_mod_content, "pub const db = @import(\"db/mod.zig\");\n" });
                defer allocator.free(updated);
                writeFile(io, project_dir, "src/core/mod.zig", updated) catch |err| {
                    fail_err = err;
                    return err;
                };
                std.debug.print("  update  {s}/src/core/mod.zig\n", .{app_name});
            }
        }
    }

    if (!effective_skip) {
        // only compile CSS if tailwindcss is already installed
        const tailwind_exists = blk: {
            project_dir.access(io, "bin/tailwindcss", .{}) catch break :blk false;
            break :blk true;
        };

        if (tailwind_exists) {
            current_step = "compile css";
            var css_child = std.process.spawn(io, .{
                .argv = &.{ "./bin/tailwindcss", "-i", "src/styles.css", "-o", "public/css/app.css" },
                .cwd = .{ .path = app_name },
            }) catch |err| {
                fail_err = err;
                return err;
            };
            const css_term = css_child.wait(io) catch |err| {
                fail_err = err;
                return err;
            };
            switch (css_term) {
                .exited => |code| if (code != 0) {
                    fail_err = error.TailwindCompileFailed;
                    return error.TailwindCompileFailed;
                },
                else => {
                    fail_err = error.TailwindCompileFailed;
                    return error.TailwindCompileFailed;
                },
            }
            std.debug.print("  CSS compiled → public/css/app.css\n", .{});
        } else {
            std.debug.print("  CSS will be compiled on first 'zig build run'\n", .{});
        }
    }

    current_step = "fetch spider";
    std.debug.print("Fetching spider from main...\n", .{});
    runZigFetch(io, app_name) catch |err| {
        fail_err = err;
        return err;
    };

    std.debug.print("\nDone! Next steps:\n", .{});
    std.debug.print("  cd {s}\n", .{app_name});
    if (use_pg and !effective_no_db) std.debug.print("  docker compose up -d db\n", .{});
    std.debug.print("  zig build run        ← downloads assets and starts server automatically\n", .{});
    std.debug.print("                         (requires spider CLI in PATH — run: spider install)\n", .{});

    if (effective_skip) {
        std.debug.print("\nwarning: assets not downloaded, run `spider install` to download them.\n", .{});
    }
}
