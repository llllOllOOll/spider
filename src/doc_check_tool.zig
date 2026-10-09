//! Internal: build-time tool behind the documentation check of `zig build
//! test`. It reads every source file of the given directories and fails,
//! listing them, when a `pub` name says neither `///` nor `// internal:`,
//! or when a file has no `//!` header. The rule is in doc_check.zig.
//!
//! Usage: spider-doc-check <root> <dir>... [--skip <text>]...
//! Directories are relative to <root>. A path containing one of the
//! `--skip` texts is not read.

const std = @import("std");
const doc_check = @import("doc_check.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alc = init.arena.allocator();

    var dirs: std.ArrayList([]const u8) = .empty;
    var skips: std.ArrayList([]const u8) = .empty;
    var root_path: ?[]const u8 = null;
    {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alc);
        defer it.deinit();
        _ = it.next();
        while (it.next()) |a| {
            if (std.mem.eql(u8, a, "--skip")) {
                try skips.append(alc, try alc.dupe(u8, it.next() orelse break));
            } else if (root_path == null) {
                root_path = try alc.dupe(u8, a);
            } else {
                try dirs.append(alc, try alc.dupe(u8, a));
            }
        }
    }
    if (root_path == null or dirs.items.len == 0) {
        std.debug.print("usage: spider-doc-check <root> <dir>... [--skip <text>]...\n", .{});
        std.process.exit(2);
    }

    var root = try std.Io.Dir.cwd().openDir(io, root_path.?, .{});
    defer root.close(io);

    var failures: usize = 0;
    for (dirs.items) |dir_path| {
        var dir = try root.openDir(io, dir_path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(alc);
        defer walker.deinit();
        walk: while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
            if (std.mem.endsWith(u8, entry.path, "_test.zig")) continue;
            const shown = try std.fs.path.join(alc, &.{ dir_path, entry.path });
            for (skips.items) |s| if (std.mem.indexOf(u8, shown, s) != null) continue :walk;

            const source = try dir.readFileAlloc(io, entry.path, alc, .limited(16 * 1024 * 1024));
            if (!std.mem.startsWith(u8, source, "//!")) {
                std.debug.print("{s}:1: the file has no //! header saying what it is for\n", .{shown});
                failures += 1;
            }
            for (try doc_check.unclassified(alc, source)) |problem| {
                std.debug.print("{s}:{d}: pub `{s}` has no /// doc comment and no `// internal:` note\n", .{ shown, problem.line, problem.name });
                failures += 1;
            }
        }
    }

    if (failures > 0) {
        std.debug.print(
            "\n{d} public name(s) or file(s) are not classified. Above each `pub`: `///` when an app uses it\n" ++
                "(it goes to the API reference), or `// internal: why` when it is public only for Spider's own files.\n",
            .{failures},
        );
        std.process.exit(1);
    }
}
