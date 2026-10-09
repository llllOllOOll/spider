//! Internal: build-time tool behind `devStep()` in build.zig. `spider dev`
//! runs `zig build dev --watch`; this is the last thing that step does, so
//! it runs after every build that succeeded and never after one that
//! failed. It tells the supervisor that a build finished and what it
//! produced.
//!
//! Usage: spider-dev-notify <built executable> [asset file...] [--templates=<dir>]
//!
//! The supervisor names a file in SPIDER_DEV_BUILT. The tool replaces it
//! (write to a temporary name, then rename: the reader never sees half a
//! file) with three lines:
//!
//!   1. the executable's absolute path;
//!   2. a number that differs on every run (the build may put a new binary
//!      at the same path);
//!   3. a hash of the asset files' contents ("-" without assets): what the
//!      page uses besides the binary, such as the generated stylesheet and,
//!      with `--templates`, every template under that directory (they are
//!      read from disk in a Debug build);
//!   4. with `--templates`, a hash of the template files' names ("-"
//!      otherwise): the running app listed them when it started, so a new,
//!      removed or renamed template needs the app restarted.
//!
//! Outside `spider dev` the variable is not set and the tool does nothing.

const std = @import("std");

pub const env_name = "SPIDER_DEV_BUILT";

/// Every .html and .md file under `dir`, by name and contents, in a fixed
/// order (a directory walk has none).
fn hashTemplates(io: std.Io, alc: std.mem.Allocator, hasher: *std.hash.XxHash3, names: *std.hash.XxHash3, dir_path: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var paths: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(alc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".html") and !std.mem.endsWith(u8, entry.path, ".md")) continue;
        try paths.append(alc, try alc.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    for (paths.items) |path| {
        names.update(path);
        names.update(&[_]u8{0});
        hasher.update(path);
        hasher.update(&[_]u8{0});
        const content = dir.readFileAlloc(io, path, alc, .limited(8 * 1024 * 1024)) catch "";
        hasher.update(content);
        hasher.update(&[_]u8{0});
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alc = init.arena.allocator();

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alc);
    defer it.deinit();
    _ = it.next();
    const exe_arg = it.next() orelse {
        std.debug.print("usage: spider-dev-notify <built executable> [asset file...]\n", .{});
        std.process.exit(2);
    };

    const built_path = init.environ_map.get(env_name) orelse return;
    if (built_path.len == 0) return;

    const cwd = std.Io.Dir.cwd();
    const exe_path = try cwd.realPathFileAlloc(io, exe_arg, alc);

    // Names and contents, in the order given. A file that is not there
    // (assets not built yet) counts as empty.
    var hasher: std.hash.XxHash3 = .init(0);
    var any_asset = false;
    var names_hasher: std.hash.XxHash3 = .init(0);
    var any_templates = false;
    while (it.next()) |asset| {
        any_asset = true;
        if (std.mem.startsWith(u8, asset, "--templates=")) {
            any_templates = true;
            try hashTemplates(io, alc, &hasher, &names_hasher, asset["--templates=".len..]);
            continue;
        }
        hasher.update(asset);
        hasher.update(&[_]u8{0});
        const content = cwd.readFileAlloc(io, asset, alc, .limited(64 * 1024 * 1024)) catch "";
        hasher.update(content);
        hasher.update(&[_]u8{0});
    }
    var assets_buf: [16]u8 = undefined;
    const assets: []const u8 = if (any_asset)
        std.fmt.bufPrint(&assets_buf, "{x:0>16}", .{hasher.final()}) catch unreachable
    else
        "-";

    var names_buf: [16]u8 = undefined;
    const template_names: []const u8 = if (any_templates)
        std.fmt.bufPrint(&names_buf, "{x:0>16}", .{names_hasher.final()}) catch unreachable
    else
        "-";

    const stamp = std.Io.Timestamp.now(io, .real).toNanoseconds();
    const content = try std.fmt.allocPrint(alc, "{s}\n{d}\n{s}\n{s}\n", .{ exe_path, stamp, assets, template_names });
    const tmp_path = try std.fmt.allocPrint(alc, "{s}.tmp", .{built_path});
    {
        const file = try cwd.createFile(io, tmp_path, .{});
        defer file.close(io);
        var buf: [1024]u8 = undefined;
        var writer: std.Io.File.Writer = .init(file, io, &buf);
        try writer.interface.writeAll(content);
        try writer.interface.flush();
    }
    try cwd.rename(tmp_path, cwd, built_path, io);
}
