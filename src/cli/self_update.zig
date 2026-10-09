const std = @import("std");

/// The install script, from spiderme.org or, when the site is down, the
/// same file in the repository. It is downloaded first and only then run,
/// so a failed download is never mistaken for a failed install.
pub const install =
    \\script=$(curl -fsSL https://spiderme.org/install.sh 2>/dev/null) \
    \\  || script=$(curl -fsSL https://raw.githubusercontent.com/llllOllOOll/spider/main/scripts/install.sh) \
    \\  || { echo "error: could not download the install script" >&2; exit 1; }
    \\printf '%s\n' "$script" | bash
;

test "self-update falls back to the repository when the site is down" {
    try std.testing.expect(std.mem.indexOf(u8, install, "spiderme.org/install.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, install, "raw.githubusercontent.com/llllOllOOll/spider/main/scripts/install.sh") != null);
}

pub fn run(io: std.Io) !void {
    std.debug.print("Updating spider CLI...\n", .{});

    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", install },
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("error: install script failed with exit code {d}\n", .{code});
            return error.SelfUpdateFailed;
        },
        else => {
            std.debug.print("error: install script terminated abnormally\n", .{});
            return error.SelfUpdateFailed;
        },
    }
}
