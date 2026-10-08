//! Build-time tool behind `devStep()` in build.zig. `spider dev` runs
//! `zig build dev --watch`; this is the last thing that step does, so it
//! runs after every build that succeeded and never after one that failed.
//! It tells the supervisor that a build finished and what it produced.
//!
//! Usage: spider-dev-notify <built executable> [asset file...]
//!
//! The supervisor names a file in SPIDER_DEV_BUILT. The tool replaces it
//! (write to a temporary name, then rename: the reader never sees half a
//! file) with three lines:
//!
//!   1. the executable's absolute path;
//!   2. a number that differs on every run (the build may put a new binary
//!      at the same path);
//!   3. a hash of the asset files' contents ("-" without assets): what the
//!      page uses besides the binary, such as the generated stylesheet.
//!
//! Outside `spider dev` the variable is not set and the tool does nothing.

const std = @import("std");

pub const env_name = "SPIDER_DEV_BUILT";

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
    while (it.next()) |asset| {
        any_asset = true;
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

    const stamp = std.Io.Timestamp.now(io, .real).toNanoseconds();
    const content = try std.fmt.allocPrint(alc, "{s}\n{d}\n{s}\n", .{ exe_path, stamp, assets });
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
