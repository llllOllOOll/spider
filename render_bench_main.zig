//! `zig build bench-render -Doptimize=ReleaseFast` (3 s per measure): see
//! src/render/render_bench.zig.

const std = @import("std");
const spider = @import("spider");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const seconds = if (args.next()) |a| try std.fmt.parseInt(u64, a, 10) else 3;
    try spider.render_bench.run(init.io, seconds);
}
