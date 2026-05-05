const std = @import("std");
const new = @import("new.zig");
const generate = @import("generate.zig");

const usage =
    \\Spider CLI — spiderme.org
    \\
    \\Usage:
    \\  spider new <app_name>          Create a new Spider project
    \\  spider generate <subcommand>   Generate code (feature)
    \\  spider help                    Show this help
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // skip program name

    const command = args.next() orelse {
        std.debug.print("{s}", .{usage});
        return;
    };

    if (std.mem.eql(u8, command, "new")) {
        const app_name = args.next() orelse {
            std.debug.print("error: missing app name\nUsage: spider new <app_name>\n", .{});
            return error.MissingAppName;
        };
        try new.run(io, allocator, app_name);
    } else if (std.mem.eql(u8, command, "generate")) {
        const subcommand = args.next() orelse {
            std.debug.print("Usage: spider generate <subcommand>\n", .{});
            return;
        };
        try generate.run(io, allocator, subcommand, &args);
    } else if (std.mem.eql(u8, command, "help")) {
        std.debug.print("{s}", .{usage});
    } else {
        std.debug.print("error: unknown command '{s}'\n{s}", .{ command, usage });
    }
}
