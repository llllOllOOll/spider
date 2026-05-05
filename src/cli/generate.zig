const std = @import("std");
const feature = @import("feature.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, subcommand: []const u8, args: *std.process.Args.Iterator) !void {
    if (std.mem.eql(u8, subcommand, "feature")) {
        const name = args.next() orelse {
            std.debug.print("Usage: spider generate feature <name>\n", .{});
            return error.MissingFeatureName;
        };
        try feature.run(io, allocator, name);
    } else {
        std.debug.print("error: unknown generate subcommand '{s}'\n", .{subcommand});
        std.debug.print("Usage: spider generate <subcommand>\n", .{});
        std.debug.print("Available subcommands:\n", .{});
        std.debug.print("  feature <name>    Generate a new feature\n", .{});
    }
}
