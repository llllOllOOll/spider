//! Internal: build-time tool behind `zig build test`'s version check. It
//! fails when `src/version.zig` and the `.version` of `build.zig.zon`
//! differ, so `spider.version` always says the version being released.
//!
//! Usage: spider-version-check <root>

const std = @import("std");
const version = @import("version.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alc = init.arena.allocator();

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alc);
    defer it.deinit();
    _ = it.next();
    const root_path = it.next() orelse {
        std.debug.print("usage: spider-version-check <root>\n", .{});
        std.process.exit(2);
    };

    var root = try std.Io.Dir.cwd().openDir(io, root_path, .{});
    defer root.close(io);
    const zon = try root.readFileAlloc(io, "build.zig.zon", alc, .limited(1024 * 1024));
    const declared = version.zonVersion(zon) orelse {
        std.debug.print("build.zig.zon: no .version found\n", .{});
        std.process.exit(1);
    };
    if (!std.mem.eql(u8, declared, version.string)) {
        std.debug.print("src/version.zig says {s} but build.zig.zon says {s}: change both in a release\n", .{ version.string, declared });
        std.process.exit(1);
    }
}
