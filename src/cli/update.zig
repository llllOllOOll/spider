const std = @import("std");
const fs_utils = @import("fs_utils.zig");

/// Asks GitHub for the latest release and saves that tag as the project's
/// Spider dependency. Releases only: never the tip of main.
pub const fetch_latest =
    \\tag=$(curl -fsSL https://api.github.com/repos/llllOllOOll/spider/releases/latest \
    \\  | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
    \\if [ -z "$tag" ]; then
    \\  echo "error: could not find the latest Spider release (is github.com reachable?)" >&2
    \\  exit 1
    \\fi
    \\echo "Latest release: $tag"
    \\zig fetch --save=spider "git+https://github.com/llllOllOOll/spider?ref=$tag"
;

test "update fetches a release tag, never a branch" {
    try std.testing.expect(std.mem.indexOf(u8, fetch_latest, "releases/latest") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetch_latest, "?ref=$tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetch_latest, "#main") == null);
}

pub fn run(io: std.Io) !void {
    const root_dir = try fs_utils.findProjectRoot(io);

    std.debug.print("Updating the spider dependency to the latest release...\n", .{});

    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", fetch_latest },
        .cwd = .{ .dir = root_dir },
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("error: zig fetch failed with exit code {d}\n", .{code});
            return error.ZigFetchFailed;
        },
        else => {
            std.debug.print("error: zig fetch terminated abnormally\n", .{});
            return error.ZigFetchFailed;
        },
    }

    std.debug.print("Done! spider dependency updated.\n", .{});
}
