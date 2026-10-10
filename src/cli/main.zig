const std = @import("std");
const new = @import("new.zig");
const generate = @import("generate.zig");
const install = @import("install.zig");
const generate_vapid = @import("generate_vapid.zig");
const migrate = @import("migrate.zig");
const update = @import("update.zig");
const self_update = @import("self_update.zig");

const cli_args = @import("args.zig");
const routes_cmd = @import("routes_cmd.zig");
const ui_mod = @import("ui.zig");
const icons_mod = @import("icons.zig");
const pwa_mod = @import("pwa.zig");
const check_mod = @import("check.zig");
const dev = @import("dev.zig");

const version = @import("version.zig").version;

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
                error.UnknownUiKit => usageError("unknown UI kit in '{s}' (kits: daisyui, tailwind)", .{bad}),
                error.UnknownHtmxVersion => usageError("unknown htmx version in '{s}' (versions: 2, 4)", .{bad}),
                error.PwaNeedsViews => usageError("--pwa needs HTML views; it can't be combined with --api", .{}),
            };
            if (o.daisyui_alias) std.debug.print("note: --daisyui is the default now (same as --ui=daisyui); the app shell with navbar and sidebar is src/shared/templates/app.html (`extends \"app\"`).\n", .{});
            try new.run(io, allocator, o.app_name, ui_mod.find(o.ui).?, o.skip_downloads, o.api, o.no_db, o.pg, o.pwa, o.htmx);
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
        .routes => {
            var bad: []const u8 = "";
            const mode = routes_cmd.parseMode(rest, &bad) catch |err| switch (err) {
                error.UnknownOption => usageError("unknown option '{s}' for `spider routes` (see `spider routes --help`)", .{bad}),
                error.TooManyOptions => usageError("`spider routes` takes one of --json, --check, --lock, --diff ('{s}')", .{bad}),
            };
            const code = try routes_cmd.run(io, allocator, init.environ_map, mode);
            if (code != 0) std.process.exit(code);
        },
        .ui => {
            const code = try ui_mod.run(io, allocator, rest);
            if (code != 0) std.process.exit(code);
        },
        .icons => {
            const code = try icons_mod.run(io, allocator, rest);
            if (code != 0) std.process.exit(code);
        },
        .check => {
            const code = try check_mod.run(io, allocator, rest);
            if (code != 0) std.process.exit(code);
        },
        .add, .remove => {
            const code = try pwa_mod.run(io, allocator, cmd == .add, rest);
            if (code != 0) std.process.exit(code);
        },
        .dev => {
            var bad: []const u8 = "";
            const dev_args = dev.Args.parse(rest, &bad) catch |err| switch (err) {
                error.UnknownOption => usageError("unknown option '{s}' for `spider dev` (see `spider dev --help`)", .{bad}),
                error.InvalidPort => usageError("--port needs a port number (got '{s}')", .{bad}),
            };
            dev.run(io, init.gpa, init.environ_map, dev_args) catch |err| switch (err) {
                error.Unsupported, error.NotAProjectRoot, error.AlreadyRunning, error.NoDevStep => std.process.exit(1),
                else => |e| return e,
            };
        },
        .update => try update.run(io),
        .self_update => try self_update.run(io),
        .install => try install.run(io, allocator, std.Io.Dir.cwd()),
        .generate_vapid => try generate_vapid.run(io, allocator, if (rest.len > 0) rest[0] else null),
        .version, .help => unreachable, // handled by decide()
    }
}

test {
    _ = cli_args;
    _ = @import("feature.zig");
    _ = @import("routes_updater.zig");
    _ = @import("auth_updater.zig");
    _ = routes_cmd;
    _ = @import("auth.zig");
    _ = @import("auth_local.zig");
    _ = @import("new.zig");
    _ = @import("update.zig");
    _ = @import("self_update.zig");
    _ = @import("mod_updater.zig");
    _ = @import("migration_updater.zig");
    _ = @import("htmx.zig");
    _ = @import("dev.zig");
    _ = ui_mod;
    _ = icons_mod;
    _ = pwa_mod;
    _ = check_mod;
}

test "every file with tests is part of the CLI test binary" {
    try @import("spider_testing").expectAllTestsDiscovered(@import("test_manifest"));
}
