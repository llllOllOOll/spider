const std = @import("std");
const fs_utils = @import("fs_utils.zig");

pub fn generateTimestamp(io: std.Io) u64 {
    const now = std.Io.Clock.now(.real, io);
    return @intCast(@divFloor(now.nanoseconds, 1_000_000_000));
}

pub fn updateMigrationsZig(io: std.Io, allocator: std.mem.Allocator, root_dir: std.Io.Dir, timestamp: u64, plural: []const u8, migrations_zig_tmpl: []const u8) !void {
    const migrations_zig_path = "src/core/db/migrations.zig";

    const new_entry = try std.fmt.allocPrint(allocator,
        "    .{{\n" ++
        "        .version = \"{d}_create_{s}\",\n" ++
        "        .sql_file = @embedFile(\"./migrations/{d}_create_{s}.sql\"),\n" ++
        "    }},\n",
        .{ timestamp, plural, timestamp, plural }
    );
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
