const std = @import("std");
const new = @import("new.zig");
const generate = @import("generate.zig");
const install = @import("install.zig");
const generate_vapid = @import("generate_vapid.zig");
const migrate = @import("migrate.zig");
const update = @import("update.zig");
const self_update = @import("self_update.zig");

const cli_args = @import("args.zig");

const version = "0.6.9";

fn writeStdout(io: std.Io, text: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    w.interface.writeAll(text) catch return;
    w.interface.flush() catch {};
}

/// Usage errors: message + hint on stderr, exit status 2.
fn usageError(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var all: std.ArrayListUnmanaged([]const u8) = .empty;
    {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
        defer it.deinit();
        _ = it.next(); // program name
        while (it.next()) |a| try all.append(allocator, try allocator.dupe(u8, a));
    }

    const cmd = switch (cli_args.decide(all.items)) {
        .help => |topic| {
            writeStdout(io, if (topic) |c| cli_args.commandHelp(c) else cli_args.overview);
            return;
        },
        .version => {
            writeStdout(io, "spider v" ++ version ++ "\n");
            return;
        },
        .unknown_command => |name| usageError("unknown command '{s}' (see `spider --help`)", .{name}),
        .run => |c| c,
    };
    const rest = all.items[1..];

    switch (cmd) {
        .new => {
            var bad: []const u8 = "";
            const o = cli_args.parseNew(rest, &bad) catch |err| switch (err) {
                error.MissingAppName => usageError("missing app name (usage: spider new <app_name> [options])", .{}),
                error.UnknownOption => usageError("unknown option '{s}' for `spider new` (see `spider new --help`)", .{bad}),
                error.ExtraArgument => usageError("unexpected argument '{s}': `spider new` takes one app name", .{bad}),
            };
            try new.run(io, allocator, o.app_name, o.daisyui, o.skip_downloads, o.api, o.no_db, o.pg);
        },
        .generate => {
            if (rest.len == 0) {
                writeStdout(io, cli_args.commandHelp(.generate));
                return;
            }
            var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
            defer it.deinit();
            _ = it.next(); // program name
            _ = it.next(); // generate / g
            _ = it.next(); // subcommand
            try generate.run(io, allocator, rest[0], &it);
        },
        .migrate => try migrate.run(io, allocator),
        .update => try update.run(io),
        .self_update => try self_update.run(io),
        .install => try install.run(io, allocator, std.Io.Dir.cwd()),
        .generate_vapid => try generate_vapid.run(io, allocator, if (rest.len > 0) rest[0] else null),
        .version, .help => unreachable, // handled by decide()
    }
}

test {
    _ = cli_args;
}

test "every file with tests is part of the CLI test binary" {
    try @import("spider_testing").expectAllTestsDiscovered(@import("test_manifest"));
}
