const std = @import("std");
const new = @import("new.zig");
const generate = @import("generate.zig");
const install = @import("install.zig");
const generate_vapid = @import("generate_vapid.zig");
const migrate = @import("migrate.zig");
const update = @import("update.zig");
const self_update = @import("self_update.zig");
const project_version = @import("project_version.zig");

const cli_args = @import("args.zig");
const routes_cmd = @import("routes_cmd.zig");
const modules_cmd = @import("modules_cmd.zig");
const fs_utils = @import("fs_utils.zig");
const ui_mod = @import("ui.zig");
const icons_mod = @import("icons.zig");
const pwa_mod = @import("pwa.zig");
const check_mod = @import("check.zig");
const dev = @import("dev.zig");
const clean_cmd = @import("clean.zig");

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

    // Work in a project whose Spider is not this CLI's own: run the CLI of
    // the project's release (does not return when it can), else say so.
    switch (cmd) {
        .new, .update, .self_update, .version, .help, .clean, .generate_vapid => {},
        else => {
            dispatchToProjectCli(io, allocator, init.environ_map, all.items);
            warnProjectVersion(io, allocator);
        },
    }

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
        .migrate => {
            var bad: []const u8 = "";
            const scope = modules_cmd.parseMigrateArgs(rest, &bad) catch
                usageError("unknown option '{s}' for `spider migrate` (see `spider migrate --help`)", .{bad});
            const root = try fs_utils.findProjectRoot(io);
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            if (modules_cmd.appEmbedsMigrations(io, arena.allocator(), root)) {
                // The binary holds every migration, the modules' and the app's.
                if (scope != .all) usageError("this app embeds its migrations (spider.addMigrations): `spider migrate` applies them all, modules first; --no-modules and --modules-only are for apps that keep them as files", .{});
                std.debug.print("Running migrations (zig build run with SPIDER_MIGRATE)...\n", .{});
                const code = try modules_cmd.runApp(io, init.environ_map, "SPIDER_MIGRATE");
                if (code != 0) std.process.exit(code);
                return;
            }
            if (scope != .app_only) {
                if (modules_cmd.appUsesModules(io, arena.allocator(), root)) {
                    // Modules first: the app's migrations may use their tables.
                    std.debug.print("Running module migrations (zig build run with SPIDER_MIGRATE)...\n", .{});
                    const code = try modules_cmd.runApp(io, init.environ_map, "SPIDER_MIGRATE");
                    if (code != 0) std.process.exit(code);
                } else if (scope == .modules_only) {
                    std.debug.print("no module mounted (no mountModules( under src/): nothing to do\n", .{});
                }
            }
            if (scope != .modules_only) try migrate.run(io, allocator);
        },
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
            const code = try check_mod.run(io, allocator, init.environ_map, rest);
            if (code != 0) std.process.exit(code);
        },
        .clean => {
            var bad: []const u8 = "";
            const mode = clean_cmd.parseMode(rest, &bad) catch usageError("unknown option '{s}' for `spider clean` (see `spider clean --help`)", .{bad});
            const code = try clean_cmd.run(io, allocator, mode);
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
        .update => try update.run(io, allocator, rest),
        .self_update => try self_update.run(io, allocator, rest),
        .install => try install.run(io, allocator, std.Io.Dir.cwd()),
        .generate_vapid => try generate_vapid.run(io, allocator, if (rest.len > 0) rest[0] else null),
        .version, .help => unreachable, // handled by decide()
    }
}

test {
    _ = cli_args;
    _ = @import("feature.zig");
    _ = project_version;
    _ = clean_cmd;
    _ = @import("build_cache.zig");
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
    _ = @import("checksums.zig");
    _ = @import("downloader.zig");
    _ = @import("install.zig");
    _ = ui_mod;
    _ = icons_mod;
    _ = pwa_mod;
    _ = check_mod;
    _ = modules_cmd;
    _ = migrate;
}

test "every file with tests is part of the CLI test binary" {
    try @import("spider_testing").expectAllTestsDiscovered(@import("test_manifest"));
}

/// Prints project_version.warning for the project around the current
/// directory, if there is one and its Spider is not this CLI's.
fn warnProjectVersion(io: std.Io, allocator: std.mem.Allocator) void {
    const root = @import("fs_utils.zig").findProjectRoot(io) catch return;
    const zon = root.readFileAlloc(io, "build.zig.zon", allocator, .limited(64 * 1024)) catch return;
    defer allocator.free(zon);
    const pin = project_version.pinOf(zon) orelse return;
    const msg = project_version.warning(allocator, version, pin) catch return orelse return;
    defer allocator.free(msg);
    std.debug.print("{s}", .{msg});
}

/// In a project pinned to another Spider release, runs that release's CLI
/// with the same arguments (it is installed once, into
/// `$XDG_CACHE_HOME/spider/cli/<version>` or `~/.cache/spider/cli/<version>`),
/// so each project keeps the CLI of its own version and nobody has to move.
/// Does not return when it runs it. Returns, and the caller warns, when the
/// project is on a branch, a commit or a local path, when that CLI cannot
/// be installed, with SPIDER_DISPATCH=0, or inside a CLI it started.
fn dispatchToProjectCli(io: std.Io, allocator: std.mem.Allocator, env: *std.process.Environ.Map, args: []const []const u8) void {
    if (env.get("SPIDER_DISPATCHED") != null) return;
    if (env.get("SPIDER_DISPATCH")) |v| if (std.mem.eql(u8, v, "0")) return;
    const root = @import("fs_utils.zig").findProjectRoot(io) catch return;
    const zon = root.readFileAlloc(io, "build.zig.zon", allocator, .limited(64 * 1024)) catch return;
    const v = switch (project_version.pinOf(zon) orelse return) {
        .release => |r| r,
        else => return,
    };
    if (std.mem.eql(u8, v, version)) return;
    // Digits and dots only: safe in the install command below.
    const target = update.parseTarget(&.{v}) catch return;
    if (target != .version) return;
    const cache = if (env.get("XDG_CACHE_HOME")) |x| x else blk: {
        const home = env.get("HOME") orelse return;
        break :blk std.fmt.allocPrint(allocator, "{s}/.cache", .{home}) catch return;
    };
    const dir = std.fmt.allocPrint(allocator, "{s}/spider/cli/{s}", .{ cache, v }) catch return;
    if (std.mem.indexOfScalar(u8, dir, '\'') != null) return;
    const exe = std.fmt.allocPrint(allocator, "{s}/spider", .{dir}) catch return;
    if (!fileExists(io, exe)) {
        std.debug.print("note: this project uses Spider v{s}; installing its spider CLI into {s} (once; SPIDER_DISPATCH=0 turns this off)\n", .{ v, dir });
        const cmd = std.fmt.allocPrint(allocator, "{s} -s -- --version {s} --install-dir '{s}' >/dev/null", .{ self_update.install, v, dir }) catch return;
        var child = std.process.spawn(io, .{ .argv = &.{ "sh", "-c", cmd } }) catch return;
        _ = child.wait(io) catch return;
        if (!fileExists(io, exe)) {
            std.debug.print("note: could not install the spider CLI v{s}; using this one (v{s})\n", .{ v, version });
            return;
        }
    }
    env.put("SPIDER_DISPATCHED", "1") catch return;
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(allocator, exe) catch return;
    argv.appendSlice(allocator, args) catch return;
    const err = std.process.replace(io, .{ .argv = argv.items, .environ_map = env });
    std.debug.print("note: could not run {s} ({s}); using this spider (v{s})\n", .{ exe, @errorName(err), version });
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}
