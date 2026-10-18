//! The modules' side of `spider check --modules` and `spider migrate`.
//!
//! Like `spider routes`, the app answers for itself: `zig build run` with
//! SPIDER_CHECK set makes listen() print the modules' report and return
//! (exit 1 when a module is not ready); with SPIDER_MIGRATE set it applies
//! the modules' migrations, and the app's own when it embeds them
//! (spider.addMigrations), and returns. An app that neither mounts modules
//! nor embeds its migrations is not built at all by `spider migrate`.
//!
//! Everything but the process spawning is pure and unit-tested below.

const std = @import("std");

/// Which migrations `spider migrate` runs.
pub const MigrateScope = enum { all, app_only, modules_only };

pub fn parseMigrateArgs(args: []const []const u8, bad: *[]const u8) error{UnknownOption}!MigrateScope {
    var scope: MigrateScope = .all;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--no-modules")) {
            scope = .app_only;
        } else if (std.mem.eql(u8, a, "--modules-only")) {
            scope = .modules_only;
        } else {
            bad.* = a;
            return error.UnknownOption;
        }
    }
    return scope;
}

/// Whether a source text mounts modules: a `mountModules(` outside a line
/// comment.
pub fn mentionsMountModules(text: []const u8) bool {
    return mentionsCall(text, "mountModules(");
}

/// Whether a build.zig embeds the app's migrations: a `addMigrations(`
/// outside a line comment (spider.addMigrations).
pub fn mentionsAddMigrations(text: []const u8) bool {
    return mentionsCall(text, "addMigrations(");
}

fn mentionsCall(text: []const u8, call: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const code = if (std.mem.indexOf(u8, line, "//")) |c| line[0..c] else line;
        if (std.mem.indexOf(u8, code, call) != null) return true;
    }
    return false;
}

/// Whether the app's build.zig embeds its migrations in the binary: then
/// the binary applies them all (SPIDER_MIGRATE), and the files are not read
/// by the CLI.
pub fn appEmbedsMigrations(io: std.Io, arena: std.mem.Allocator, root: std.Io.Dir) bool {
    const text = root.readFileAlloc(io, "build.zig", arena, .limited(8 * 1024 * 1024)) catch return false;
    return mentionsAddMigrations(text);
}

/// Whether any .zig file under the app's src/ mounts modules.
pub fn appUsesModules(io: std.Io, arena: std.mem.Allocator, root: std.Io.Dir) bool {
    var src = root.openDir(io, "src", .{ .iterate = true }) catch return false;
    defer src.close(io);
    var walker = src.walk(arena) catch return false;
    defer walker.deinit();
    while (walker.next(io) catch return false) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const text = src.readFileAlloc(io, entry.path, arena, .limited(8 * 1024 * 1024)) catch continue;
        if (mentionsMountModules(text)) return true;
    }
    return false;
}

/// Builds and runs the app with `variable` set, its output passed through;
/// returns its exit code.
pub fn runApp(io: std.Io, environ_map: *std.process.Environ.Map, variable: []const u8) !u8 {
    try environ_map.put(variable, "1");
    var child = try std.process.spawn(io, .{ .argv = &.{ "zig", "build", "run" }, .environ_map = environ_map });
    return switch (try child.wait(io)) {
        .exited => |code| code,
        else => 1,
    };
}

test "parseMigrateArgs: all by default, one scope flag" {
    var bad: []const u8 = "";
    try std.testing.expectEqual(MigrateScope.all, try parseMigrateArgs(&.{}, &bad));
    try std.testing.expectEqual(MigrateScope.app_only, try parseMigrateArgs(&.{"--no-modules"}, &bad));
    try std.testing.expectEqual(MigrateScope.modules_only, try parseMigrateArgs(&.{"--modules-only"}, &bad));
    try std.testing.expectError(error.UnknownOption, parseMigrateArgs(&.{"--force"}, &bad));
    try std.testing.expectEqualStrings("--force", bad);
}

test "mentionsMountModules: code, not comments" {
    try std.testing.expect(mentionsMountModules("    _ = server.mountModules(.{notify});"));
    try std.testing.expect(mentionsMountModules("try s\n  .mountModules(.{ a, b })\n  .listen(.{});"));
    try std.testing.expect(!mentionsMountModules("// call mountModules(.{x}) later"));
    try std.testing.expect(!mentionsMountModules("_ = server.mountFeatures(features);"));
}

test "mentionsAddMigrations: code, not comments" {
    try std.testing.expect(mentionsAddMigrations("    exe.root_module.addImport(\"migrations\", spider_build.addMigrations(b, spider_dep, \"src/core/db/migrations\"));"));
    try std.testing.expect(!mentionsAddMigrations("// spider_build.addMigrations(b, spider_dep, dir) later"));
    try std.testing.expect(!mentionsAddMigrations("const tool = spider_dep.artifact(\"spider-test-manifest\");"));
}
