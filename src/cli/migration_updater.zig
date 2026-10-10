const std = @import("std");
const fs_utils = @import("fs_utils.zig");

/// The number a new migration gets: the current second, or one more than
/// the highest number already in `src/core/db/migrations/` when that is not
/// greater. Two generators run in the same second used to give two
/// migrations the same number, and their order was then only the order of
/// a list in a source file.
pub fn generateTimestamp(io: std.Io, root_dir: std.Io.Dir) u64 {
    const now = std.Io.Clock.now(.real, io);
    const seconds: u64 = @intCast(@divFloor(now.nanoseconds, 1_000_000_000));
    return after(seconds, highestIn(io, root_dir));
}

fn after(now: u64, highest: u64) u64 {
    return if (now > highest) now else highest + 1;
}

/// The number a migration file name starts with ("1791667710_create_rooms.sql"
/// -> 1791667710), or null for a name that does not start with one.
fn numberOf(name: []const u8) ?u64 {
    const end = std.mem.indexOfScalar(u8, name, '_') orelse return null;
    return std.fmt.parseInt(u64, name[0..end], 10) catch null;
}

fn highestIn(io: std.Io, root_dir: std.Io.Dir) u64 {
    var dir = root_dir.openDir(io, "src/core/db/migrations", .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var highest: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (numberOf(entry.name)) |n| highest = @max(highest, n);
    }
    return highest;
}

test "a new migration is numbered after every one there is" {
    try std.testing.expectEqual(@as(u64, 1791667710), after(1791667710, 0));
    try std.testing.expectEqual(@as(u64, 1791667710), after(1791667710, 1791551322));
    // The same second as the last one, or a clock that went back: one more.
    try std.testing.expectEqual(@as(u64, 1791667711), after(1791667710, 1791667710));
    try std.testing.expectEqual(@as(u64, 1791667716), after(1791667710, 1791667715));

    try std.testing.expectEqual(@as(?u64, 1791667710), numberOf("1791667710_create_rooms.sql"));
    try std.testing.expectEqual(@as(?u64, null), numberOf("README.md"));
    try std.testing.expectEqual(@as(?u64, null), numberOf("notes_about_things.sql"));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try std.testing.expectEqual(@as(u64, 0), highestIn(io, tmp.dir)); // no migrations yet
    try tmp.dir.createDirPath(io, "src/core/db/migrations");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/core/db/migrations/1791667710_create_rooms.sql", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/core/db/migrations/1791551322_seed.sql", .data = "" });
    try std.testing.expectEqual(@as(u64, 1791667710), highestIn(io, tmp.dir));

    // Two generators in a row, whatever the clock says: two different numbers.
    const first = generateTimestamp(io, tmp.dir);
    var name_buf: [96]u8 = undefined;
    try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name_buf, "src/core/db/migrations/{d}_create_a.sql", .{first}), .data = "" });
    const second = generateTimestamp(io, tmp.dir);
    try std.testing.expect(second > first);
}

pub fn updateMigrationsZig(io: std.Io, allocator: std.mem.Allocator, root_dir: std.Io.Dir, timestamp: u64, plural: []const u8, migrations_zig_tmpl: []const u8) !void {
    const migrations_zig_path = "src/core/db/migrations.zig";

    const new_entry = try std.fmt.allocPrint(allocator, "    .{{\n" ++
        "        .version = \"{d}_create_{s}\",\n" ++
        "        .sql_file = @embedFile(\"./migrations/{d}_create_{s}.sql\"),\n" ++
        "    }},\n", .{ timestamp, plural, timestamp, plural });
    defer allocator.free(new_entry);

    const existing = root_dir.readFileAlloc(io, migrations_zig_path, allocator, .limited(64 * 1024)) catch "";
    defer if (existing.len > 0) allocator.free(existing);

    if (existing.len == 0) {
        const content = try std.mem.replaceOwned(u8, allocator, migrations_zig_tmpl, "{{entry}}", new_entry);
        defer allocator.free(content);
        try fs_utils.writeFile(io, root_dir, migrations_zig_path, content);
    } else {
        const marker = "};\n\nfn extractUpSection";
        const pos = std.mem.indexOf(u8, existing, marker) orelse {
            std.debug.print("warning: could not find MIGRATIONS closing in migrations.zig\n", .{});
            return;
        };
        const new_content = try std.mem.concat(allocator, u8, &.{
            existing[0..pos],
            new_entry,
            existing[pos..],
        });
        defer allocator.free(new_content);
        try fs_utils.writeFile(io, root_dir, migrations_zig_path, new_content);
    }
}
