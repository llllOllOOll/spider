const std = @import("std");
const builtin = @import("builtin");
const downloader = @import("downloader.zig");
const chmod = @import("chmod.zig");
const fs_utils = @import("fs_utils.zig");
const icons = @import("icons.zig");

// Asset versions — update when creating a new Spider release
const TAILWIND_VERSION = "4.3.0";
const DAISYUI_VERSION = "5.5.23";
const ALPINE_VERSION = "3.14.8";
const HTMX_VERSION = "2.0.11";
const HTMX4_VERSION = "4.0.0";
const htmx = @import("htmx.zig");
const TABLER_VERSION = "3.31.0";

fn getTailwindUrl() []const u8 {
    const os = builtin.os.tag;
    const arch = builtin.cpu.arch;
    const base = "https://github.com/tailwindlabs/tailwindcss/releases/download/v" ++ TAILWIND_VERSION ++ "/tailwindcss-";
    if (os == .windows) return base ++ "windows-x64.exe";
    if (os == .macos and arch == .aarch64) return base ++ "macos-arm64";
    if (os == .macos) return base ++ "macos-x64";
    if (arch == .aarch64) return base ++ "linux-arm64";
    return base ++ "linux-x64";
}

pub fn getCacheDir(allocator: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("XDG_CACHE_HOME")) |xdg| {
        const s = std.mem.span(xdg);
        if (s.len > 0) return std.fmt.allocPrint(allocator, "{s}/spider", .{s});
    }

    if (std.c.getenv("HOME")) |home| {
        const h = std.mem.span(home);
        if (h.len > 0) {
            if (builtin.os.tag == .macos) {
                return std.fmt.allocPrint(allocator, "{s}/Library/Caches/spider", .{h});
            }
            return std.fmt.allocPrint(allocator, "{s}/.cache/spider", .{h});
        }
    }

    if (std.c.getenv("LOCALAPPDATA")) |appdata| {
        const a = std.mem.span(appdata);
        if (a.len > 0) return std.fmt.allocPrint(allocator, "{s}/spider/cache", .{a});
    }

    return error.CacheDirNotFound;
}

fn downloadToProject(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    project_dir: std.Io.Dir,
    dest: []const u8,
    _: []const u8,
) !bool {
    project_dir.access(io, dest, .{}) catch {
        std.debug.print("  downloading: {s}\n", .{dest});
        try downloader.download(io, allocator, url, project_dir, dest);
        return true;
    };
    return false;
}

fn downloadWithCache(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    project_dir: std.Io.Dir,
    dest: []const u8,
    cache_dir: std.Io.Dir,
    cache_name: []const u8,
) !bool {
    // Already installed in project?
    if (project_dir.access(io, dest, .{})) |_| {
        return false;
    } else |_| {}

    // Check cache
    const from_cache = blk: {
        cache_dir.access(io, cache_name, .{}) catch break :blk false;
        break :blk true;
    };

    if (!from_cache) {
        std.debug.print("  downloading: {s}\n", .{dest});
        try downloader.download(io, allocator, url, cache_dir, cache_name);
    } else {
        std.debug.print("  from cache: {s}\n", .{dest});
    }

    // Copy from cache to project
    const content = try cache_dir.readFileAlloc(io, cache_name, allocator, .limited(200 * 1024 * 1024));
    defer allocator.free(content);

    if (std.fs.path.dirname(dest)) |dir_path| {
        project_dir.createDirPath(io, dir_path) catch {};
    }
    try fs_utils.writeFile(io, project_dir, dest, content);

    return true;
}

fn usesTablerWebfont(io: std.Io, allocator: std.mem.Allocator, project_dir: std.Io.Dir) bool {
    const layout = project_dir.readFileAlloc(io, "src/shared/templates/layout.html", allocator, .limited(1024 * 1024)) catch return false;
    defer allocator.free(layout);
    return std.mem.indexOf(u8, layout, "tabler-icons.min.css") != null;
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, project_dir: std.Io.Dir) !void {
    // verify we're in a Spider project before downloading anything
    project_dir.access(io, "spider.config.zig", .{}) catch {
        std.debug.print("error: spider.config.zig not found\n", .{});
        std.debug.print("Make sure you're in a Spider project directory.\n", .{});
        std.debug.print("Run 'spider new <app_name>' to create a new project.\n", .{});
        return error.NotASpiderProject;
    };

    const Asset = struct { url: []const u8, dest: []const u8, cache_name: []const u8 };
    var assets: std.ArrayListUnmanaged(Asset) = .empty;
    defer assets.deinit(allocator);
    // URLs use pinned versions for reproducible builds and caching.
    try assets.appendSlice(allocator, &.{
        .{ .url = getTailwindUrl(), .dest = "bin/tailwindcss", .cache_name = "tailwindcss-" ++ TAILWIND_VERSION },
        .{ .url = "https://cdn.jsdelivr.net/npm/alpinejs@" ++ ALPINE_VERSION ++ "/dist/cdn.min.js", .dest = "public/js/alpine.min.js", .cache_name = "alpine-" ++ ALPINE_VERSION ++ ".min.js" },
    });

    // htmx: the one the layouts load (htmx.zig). htmx 4 goes to a file of
    // its own name, and its SSE extension is fetched when a layout loads it.
    const read_layouts: ?[][]const u8 = htmx.readLayouts(io, allocator, project_dir) catch null;
    defer if (read_layouts) |list| htmx.freeLayouts(allocator, list);
    const layouts: []const []const u8 = read_layouts orelse &.{};
    if (htmx.ofLayouts(layouts) == .four) {
        try assets.append(allocator, .{ .url = "https://unpkg.com/htmx.org@" ++ HTMX4_VERSION ++ "/dist/htmx.min.js", .dest = "public/js/" ++ htmx.file_four, .cache_name = "htmx-" ++ HTMX4_VERSION ++ ".min.js" });
        if (htmx.wantsSse(layouts)) {
            try assets.append(allocator, .{ .url = "https://unpkg.com/htmx.org@" ++ HTMX4_VERSION ++ "/dist/ext/hx-sse.min.js", .dest = "public/js/" ++ htmx.file_four_sse, .cache_name = "htmx-sse-" ++ HTMX4_VERSION ++ ".min.js" });
        }
    } else {
        try assets.append(allocator, .{ .url = "https://unpkg.com/htmx.org@" ++ HTMX_VERSION ++ "/dist/htmx.min.js", .dest = "public/js/" ++ htmx.file_two, .cache_name = "htmx-" ++ HTMX_VERSION ++ ".min.js" });
    }

    const styles = project_dir.readFileAlloc(io, "src/styles.css", allocator, .limited(1024 * 1024)) catch "";
    defer if (styles.len > 0) allocator.free(styles);
    const ui_css = project_dir.readFileAlloc(io, "src/ui.css", allocator, .limited(1024 * 1024)) catch "";
    defer if (ui_css.len > 0) allocator.free(ui_css);

    // daisyUI only when the UI kit (src/ui.css, or styles.css in apps made
    // before UI kits) loads it.
    if (std.mem.indexOf(u8, ui_css, "daisyui.mjs") != null or std.mem.indexOf(u8, styles, "daisyui.mjs") != null) {
        try assets.appendSlice(allocator, &.{
            .{ .url = "https://github.com/saadeghi/daisyui/releases/download/v" ++ DAISYUI_VERSION ++ "/daisyui.mjs", .dest = "bin/daisyui.mjs", .cache_name = "daisyui-" ++ DAISYUI_VERSION ++ ".mjs" },
            .{ .url = "https://github.com/saadeghi/daisyui/releases/download/v" ++ DAISYUI_VERSION ++ "/daisyui-theme.mjs", .dest = "bin/daisyui-theme.mjs", .cache_name = "daisyui-theme-" ++ DAISYUI_VERSION ++ ".mjs" },
        });
    }

    // The Tabler webfont, for apps generated before SVG icons (their layout
    // links /css/tabler-icons.min.css). The CSS loads its font from
    // ./fonts/ next to it: public/css/fonts/.
    if (usesTablerWebfont(io, allocator, project_dir)) {
        try assets.appendSlice(allocator, &.{
            .{ .url = "https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@" ++ TABLER_VERSION ++ "/dist/tabler-icons.min.css", .dest = "public/css/tabler-icons.min.css", .cache_name = "tabler-icons-" ++ TABLER_VERSION ++ ".css" },
            .{ .url = "https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@" ++ TABLER_VERSION ++ "/dist/fonts/tabler-icons.woff2", .dest = "public/css/fonts/tabler-icons.woff2", .cache_name = "tabler-icons-" ++ TABLER_VERSION ++ ".woff2" },
        });
    }

    // Try to setup global cache
    const cache_path = getCacheDir(allocator) catch null;

    const cache_dir: ?std.Io.Dir = if (cache_path) |cp| blk: {
        std.Io.Dir.cwd().createDirPath(io, cp) catch {};
        break :blk std.Io.Dir.openDirAbsolute(io, cp, .{}) catch null;
    } else null;

    var downloaded: usize = 0;

    for (assets.items) |asset| {
        if (cache_dir) |cd| {
            const did_download = downloadWithCache(io, allocator, asset.url, project_dir, asset.dest, cd, asset.cache_name) catch |err| blk: {
                std.debug.print("  warning: {s} failed: {s}\n", .{ asset.cache_name, @errorName(err) });
                break :blk false;
            };
            if (did_download) downloaded += 1;
        } else {
            const did_download = downloadToProject(io, allocator, asset.url, project_dir, asset.dest, asset.cache_name) catch |err| blk: {
                std.debug.print("  warning: {s} download failed: {s}\n", .{ asset.cache_name, @errorName(err) });
                break :blk false;
            };
            if (did_download) downloaded += 1;
        }
    }

    // Icon sets listed in src/styles.css (spider icons add|remove).
    const active = icons.activeSets(allocator, styles) catch &.{};
    defer if (active.len > 0) allocator.free(active);
    for (active) |name| {
        const set = icons.find(name) orelse {
            std.debug.print("  warning: unknown icon set '{s}' in src/styles.css\n", .{name});
            continue;
        };
        icons.install(io, allocator, project_dir, set, cache_dir) catch |err|
            std.debug.print("  warning: icons {s} failed: {s}\n", .{ name, @errorName(err) });
    }

    if (cache_dir) |cd| {
        cd.close(io);
    }
    if (cache_path) |cp| {
        allocator.free(cp);
    }

    if (downloaded > 0) {
        const tailwind_path = std.fmt.allocPrint(allocator, "{s}/bin/tailwindcss", .{"."}) catch return;
        defer allocator.free(tailwind_path);
        chmod.makeExecutable(io, tailwind_path) catch |err| {
            std.debug.print("  warning: chmod tailwindcss failed: {s}\n", .{@errorName(err)});
        };
        std.debug.print("Done. {d} asset(s) downloaded.\n", .{downloaded});
    }
}
