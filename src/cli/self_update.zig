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

const update = @import("update.zig");

/// Installs the spider CLI of `args`' target: the latest release (nothing
/// or `--stable`), a release (`X.Y.Z`), or a build of the develop branch
/// (`--canary`, needs git and zig).
pub fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const target = update.parseTarget(args) catch |err| {
        std.debug.print("error: {s} (usage: spider self-update [X.Y.Z | --canary | --stable])\n", .{switch (err) {
            error.UnknownArgument => "not a version or an option",
            error.TooManyArguments => "too many arguments",
        }});
        return err;
    };
    const script_args: []const u8 = switch (target) {
        .latest => "",
        .canary => "--version canary",
        // parseTarget keeps digits and dots only: safe in the command.
        .version => |v| try std.fmt.allocPrint(allocator, "--version {s}", .{v}),
        .patch => {
            std.debug.print("error: --patch is for `spider update` (a project's dependency)\n", .{});
            return error.UnknownArgument;
        },
    };
    std.debug.print("Updating spider CLI...\n", .{});
    const cmd = try std.fmt.allocPrint(allocator, "{s} -s -- {s}", .{ install, script_args });

    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", cmd },
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
