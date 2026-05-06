const std = @import("std");
const downloader = @import("downloader.zig");
const chmod = @import("chmod.zig");

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
const gitignore_tmpl = @embedFile("templates/.gitignore.template");
const core_mod_tmpl = @embedFile("templates/core_mod.zig.template");
const features_mod_tmpl = @embedFile("templates/features_mod.zig.template");
const home_mod_tmpl = @embedFile("templates/home_mod.zig.template");
const styles_css_tmpl = @embedFile("templates/styles.css.template");

fn getTailwindUrl() []const u8 {
    const os = @import("builtin").os.tag;
    const arch = @import("builtin").cpu.arch;
    if (os == .macos and arch == .aarch64) return "https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-macos-arm64";
    if (os == .macos) return "https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-macos-x64";
    if (arch == .aarch64) return "https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-linux-arm64";
    return "https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-linux-x64";
}

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

fn render(allocator: std.mem.Allocator, tmpl: []const u8, app_name: []const u8, fingerprint: []const u8) ![]const u8 {
    const step1 = try std.mem.replaceOwned(u8, allocator, tmpl, "{{app_name}}", app_name);
    defer allocator.free(step1);
    return std.mem.replaceOwned(u8, allocator, step1, "{{fingerprint}}", fingerprint);
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

pub fn run(io: std.Io, allocator: std.mem.Allocator, app_name: []const u8) !void {
    const cwd = std.Io.Dir.cwd();

    cwd.createDir(io, app_name, .default_dir) catch |err| {
        if (err == error.PathAlreadyExists) {
            std.debug.print("error: directory '{s}' already exists\n", .{app_name});
            return error.DirExists;
        }
        return err;
    };

    errdefer {
        std.debug.print("  Cleaning up {s}/...\n", .{app_name});
        cwd.deleteTree(io, app_name) catch {};
    }

    try runZigInit(io, app_name);

    var project_dir = try cwd.openDir(io, app_name, .{});
    defer project_dir.close(io);

    project_dir.createDirPath(io, "bin") catch {};
    project_dir.createDirPath(io, "public/js") catch {};
    project_dir.createDirPath(io, "public/css") catch {};

    try downloader.download(io, allocator, getTailwindUrl(), project_dir, "bin/tailwindcss");
    try downloader.download(io, allocator, "https://github.com/saadeghi/daisyui/releases/latest/download/daisyui.mjs", project_dir, "bin/daisyui.mjs");
    try downloader.download(io, allocator, "https://github.com/saadeghi/daisyui/releases/latest/download/daisyui-theme.mjs", project_dir, "bin/daisyui-theme.mjs");
    try downloader.download(io, allocator, "https://cdn.jsdelivr.net/npm/alpinejs@latest/dist/cdn.min.js", project_dir, "public/js/alpine.min.js");

    const tailwind_path = try std.fmt.allocPrint(allocator, "{s}/bin/tailwindcss", .{app_name});
    defer allocator.free(tailwind_path);
    try chmod.makeExecutable(io, tailwind_path);

    const fingerprint = try readFingerprint(io, allocator, project_dir);
    defer allocator.free(fingerprint);

    std.debug.print("Creating {s}...\n", .{app_name});

    const files = .{
        .{ "build.zig", build_zig_tmpl },
        .{ "build.zig.zon", build_zon_tmpl },
        .{ "spider.config.zig", spider_config_tmpl },
        .{ "src/main.zig", main_zig_tmpl },
        .{ "src/styles.css", styles_css_tmpl },
        .{ "src/embedded_templates.zig", "// Generated file - DO NOT EDIT MANUALLY\npub const EmbeddedTemplates = struct {};\n" },
        .{ "src/core/mod.zig", core_mod_tmpl },
        .{ "src/features/mod.zig", features_mod_tmpl },
        .{ "src/features/home/mod.zig", home_mod_tmpl },
        .{ "src/shared/templates/layout.html", layout_html_tmpl },
        .{ "src/features/home/views/index.html", home_index_tmpl },
        .{ "src/features/home/controller.zig", home_controller_tmpl },
        .{ "Dockerfile", dockerfile_tmpl },
        .{ "docker-compose.yml", docker_compose_tmpl },
        .{ ".env.example", env_example_tmpl },
        .{ ".gitignore", gitignore_tmpl },
    };

    inline for (files) |f| {
        const path = f[0];
        const tmpl = f[1];
        const content = try render(allocator, tmpl, app_name, fingerprint);
        defer allocator.free(content);
        try writeFile(io, project_dir, path, content);
        std.debug.print("  create  {s}/{s}\n", .{ app_name, path });
    }

    var css_child = try std.process.spawn(io, .{
        .argv = &.{ "./bin/tailwindcss", "-i", "src/styles.css", "-o", "public/css/app.css" },
        .cwd = .{ .path = app_name },
    });
    const css_term = try css_child.wait(io);
    switch (css_term) {
        .exited => |code| if (code != 0) return error.TailwindCompileFailed,
        else => return error.TailwindCompileFailed,
    }
    std.debug.print("  CSS compiled → public/css/app.css\n", .{});

    std.debug.print("Fetching spider from main...\n", .{});
    try runZigFetch(io, app_name);

    std.debug.print("\nDone! Next steps:\n", .{});
    std.debug.print("  cd {s}\n", .{app_name});
    std.debug.print("  zig build run\n", .{});
}
