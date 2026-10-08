//! Build-time tool behind `devStep()` in build.zig. `spider dev` runs
//! `zig build dev --watch`; this is the last thing that step does, so it
//! runs after every build that succeeded and never after one that failed.
//! It tells the supervisor that a new binary exists and where it is.
//!
//! Usage: spider-dev-notify <built executable>
//!
//! The supervisor names a file in SPIDER_DEV_BUILT. The tool replaces it
//! (write to a temporary name, then rename: the reader never sees half a
//! file) with two lines: the executable's absolute path, and a number that
//! differs on every run (the build may put a new binary at the same path).
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
        std.debug.print("usage: spider-dev-notify <built executable>\n", .{});
        std.process.exit(2);
    };

    const built_path = init.environ_map.get(env_name) orelse return;
    if (built_path.len == 0) return;

    const exe_path = try std.Io.Dir.cwd().realPathFileAlloc(io, exe_arg, alc);
    const stamp = std.Io.Timestamp.now(io, .real).toNanoseconds();
    const content = try std.fmt.allocPrint(alc, "{s}\n{d}\n", .{ exe_path, stamp });
    const tmp_path = try std.fmt.allocPrint(alc, "{s}.tmp", .{built_path});

    const cwd = std.Io.Dir.cwd();
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
