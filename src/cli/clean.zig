//! `spider clean`: frees the disk a project's build cache took. Zig never
//! removes old outputs from `.zig-cache`; every Spider build already prunes
//! them (keeping two copies of each binary, see build_cache.zig), and this
//! command keeps one. `--all` deletes the whole cache: the next build
//! compiles everything again.

const std = @import("std");
const build_cache = @import("build_cache.zig");

pub const Mode = enum { old, all };

pub const ParseError = error{UnknownOption};

/// `args` are the ones after `clean`.
pub fn parseMode(args: []const []const u8, bad: *[]const u8) ParseError!Mode {
    var mode: Mode = .old;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--all")) {
            mode = .all;
        } else {
            bad.* = a;
            return error.UnknownOption;
        }
    }
    return mode;
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, mode: Mode) !u8 {
    const cwd = std.Io.Dir.cwd();
    var cache = cwd.openDir(io, ".zig-cache", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("no .zig-cache here: nothing to clean\n", .{});
            return 0;
        },
        else => return err,
    };
    switch (mode) {
        .old => {
            defer cache.close(io);
            const r = build_cache.prune(io, allocator, cache, .{ .keep = 1, .min_age_ns = 0 });
            std.debug.print("removed {d} old build output(s) from .zig-cache ({d} MB)\n", .{ r.removed, r.freed_bytes / (1024 * 1024) });
        },
        .all => {
            cache.close(io);
            try cwd.deleteTree(io, ".zig-cache");
            std.debug.print("removed .zig-cache: the next build compiles everything again\n", .{});
        },
    }
    return 0;
}

test "parseMode: nothing or --all" {
    var bad: []const u8 = "";
    try std.testing.expectEqual(Mode.old, try parseMode(&.{}, &bad));
    try std.testing.expectEqual(Mode.all, try parseMode(&.{"--all"}, &bad));
    try std.testing.expectError(error.UnknownOption, parseMode(&.{"--force"}, &bad));
    try std.testing.expectEqualStrings("--force", bad);
}
