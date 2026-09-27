const std = @import("std");
const feature = @import("feature.zig");
const auth = @import("auth.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, subcommand: []const u8, args: *std.process.Args.Iterator) !void {
    if (std.mem.eql(u8, subcommand, "feature")) {
        const name = args.next() orelse {
            std.debug.print("Usage: spider generate feature <name> [--api]\n", .{});
            return error.MissingFeatureName;
        };
        var api = false;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--api")) {
                api = true;
            } else {
                std.debug.print("warning: unknown argument '{s}'\n", .{arg});
            }
        }
        try feature.run(io, allocator, name, api);
    } else if (std.mem.eql(u8, subcommand, "auth")) {
        var provider: []const u8 = "keycloak";
        var api = false;
        while (args.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--provider=")) {
                provider = arg["--provider=".len..];
            } else if (std.mem.eql(u8, arg, "--api")) {
                api = true;
            } else {
                std.debug.print("warning: unknown argument '{s}'\n", .{arg});
            }
        }
        try auth.run(io, allocator, provider, api);
    } else {
        std.debug.print("error: unknown generate subcommand '{s}'\n", .{subcommand});
        std.debug.print("Usage: spider generate <subcommand>\n", .{});
        std.debug.print("Available subcommands:\n", .{});
        std.debug.print("  feature <name> [--api]    Generate a new feature (--api for REST API)\n", .{});
        std.debug.print("  auth [--provider=keycloak] [--api]  Generate auth feature (--api for bearer-only)\n", .{});
    }
}
