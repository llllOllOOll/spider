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

const project_version = @import("project_version.zig");

const repo = "https://github.com/llllOllOOll/spider";

/// Where `spider update` (and `spider self-update`) go.
pub const Target = union(enum) {
    /// The latest release (the default; also `--stable`).
    latest,
    /// A release, `X.Y.Z` (written with or without the `v`).
    version: []const u8,
    /// The development branch, `develop` (`--canary`).
    canary,
    /// The latest patch of the project's release line (`--patch`).
    patch,
};

pub const TargetError = error{ UnknownArgument, TooManyArguments };

/// The target in `args`: nothing, `--stable`, `--canary`, `--patch` or a
/// version. A version is digits and dots only (after an optional `v`), so
/// it is safe in a shell command.
pub fn parseTarget(args: []const []const u8) TargetError!Target {
    if (args.len == 0) return .latest;
    if (args.len > 1) return error.TooManyArguments;
    const a = args[0];
    if (std.mem.eql(u8, a, "--stable") or std.mem.eql(u8, a, "latest")) return .latest;
    if (std.mem.eql(u8, a, "--canary") or std.mem.eql(u8, a, "canary") or std.mem.eql(u8, a, "develop")) return .canary;
    if (std.mem.eql(u8, a, "--patch")) return .patch;
    const v = if (a.len > 0 and a[0] == 'v') a[1..] else a;
    if (!isVersion(v)) return error.UnknownArgument;
    return .{ .version = v };
}

fn isVersion(v: []const u8) bool {
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, v, '.');
    while (it.next()) |p| {
        if (p.len == 0) return false;
        for (p) |c| if (!std.ascii.isDigit(c)) return false;
        parts += 1;
    }
    return parts == 3;
}

/// Whether `git ls-remote --tags` output lists tag `tag`.
pub fn tagListed(ls_remote: []const u8, tag: []const u8) bool {
    var lines = std.mem.tokenizeAny(u8, ls_remote, "\r\n");
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, "refs/tags/") orelse continue;
        const name = std.mem.trimEnd(u8, line[at + "refs/tags/".len ..], "^{}");
        if (std.mem.eql(u8, name, tag)) return true;
    }
    return false;
}

/// The highest `X.Y.Z` among the tags `vX.Y.Z` of `ls_remote` whose `X.Y`
/// is `line` (like "0.12"), or null.
pub fn latestPatch(ls_remote: []const u8, line: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_patch: u64 = 0;
    var lines = std.mem.tokenizeAny(u8, ls_remote, "\r\n");
    while (lines.next()) |l| {
        const at = std.mem.indexOf(u8, l, "refs/tags/v") orelse continue;
        const name = std.mem.trimEnd(u8, l[at + "refs/tags/v".len ..], "^{}");
        if (!isVersion(name)) continue;
        if (!std.mem.startsWith(u8, name, line) or name.len <= line.len or name[line.len] != '.') continue;
        const patch = std.fmt.parseInt(u64, name[line.len + 1 ..], 10) catch continue;
        if (best == null or patch > best_patch) {
            best = name;
            best_patch = patch;
        }
    }
    return best;
}

/// `git ls-remote --tags` of Spider's repository, or null when git is not
/// there or does not answer.
pub fn lsRemoteTags(io: std.Io, allocator: std.mem.Allocator) ?[]u8 {
    const res = std.process.run(allocator, io, .{ .argv = &.{ "git", "ls-remote", "--tags", repo } }) catch return null;
    allocator.free(res.stderr);
    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        allocator.free(res.stdout);
        return null;
    }
    return res.stdout;
}

/// Moves the project's Spider dependency to `args`' target (see Target).
pub fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const target = parseTarget(args) catch |err| {
        std.debug.print("error: {s} (usage: spider update [X.Y.Z | --patch | --canary | --stable])\n", .{switch (err) {
            error.UnknownArgument => "not a version or an option",
            error.TooManyArguments => "too many arguments",
        }});
        return err;
    };
    const root_dir = try fs_utils.findProjectRoot(io);
    switch (target) {
        .latest => {
            std.debug.print("Updating the spider dependency to the latest release...\n", .{});
            try runShell(io, root_dir, fetch_latest);
        },
        .canary => {
            std.debug.print("Updating the spider dependency to the develop branch (development)...\n", .{});
            try fetch(io, allocator, root_dir, "git+" ++ repo ++ "#develop");
        },
        .version => |v| {
            const tag = try std.fmt.allocPrint(allocator, "v{s}", .{v});
            defer allocator.free(tag);
            try requireTag(io, allocator, tag);
            std.debug.print("Updating the spider dependency to {s}...\n", .{tag});
            const url = try std.fmt.allocPrint(allocator, "git+{s}?ref={s}", .{ repo, tag });
            defer allocator.free(url);
            try fetch(io, allocator, root_dir, url);
        },
        .patch => {
            const zon = try root_dir.readFileAlloc(io, "build.zig.zon", allocator, .limited(64 * 1024));
            defer allocator.free(zon);
            const current = switch (project_version.pinOf(zon) orelse return error.NoSpiderDependency) {
                .release => |v| v,
                else => {
                    std.debug.print("error: --patch needs a project on a release (?ref=vX.Y.Z)\n", .{});
                    return error.NotOnARelease;
                },
            };
            const line = current[0..std.mem.lastIndexOfScalar(u8, current, '.').?];
            const tags = lsRemoteTags(io, allocator) orelse {
                std.debug.print("error: could not list Spider's releases (is github.com reachable?)\n", .{});
                return error.NoTags;
            };
            defer allocator.free(tags);
            const newest = latestPatch(tags, line) orelse current;
            if (std.mem.eql(u8, newest, current)) {
                std.debug.print("Already on the latest patch of {s}: v{s}.\n", .{ line, current });
                return;
            }
            std.debug.print("Updating the spider dependency from v{s} to v{s}...\n", .{ current, newest });
            const url = try std.fmt.allocPrint(allocator, "git+{s}?ref=v{s}", .{ repo, newest });
            defer allocator.free(url);
            try fetch(io, allocator, root_dir, url);
        },
    }
    std.debug.print("Done! spider dependency updated.\n", .{});
}

/// `zig fetch` of a tag that does not exist saves the default branch under
/// the tag's name without a word: the tag is checked first.
fn requireTag(io: std.Io, allocator: std.mem.Allocator, tag: []const u8) !void {
    const tags = lsRemoteTags(io, allocator) orelse return; // no answer: zig fetch decides
    defer allocator.free(tags);
    if (!tagListed(tags, tag)) {
        std.debug.print("error: Spider {s} is not published (see https://github.com/llllOllOOll/spider/tags)\n", .{tag});
        return error.NoSuchRelease;
    }
}

fn fetch(io: std.Io, allocator: std.mem.Allocator, root_dir: std.Io.Dir, url: []const u8) !void {
    _ = allocator;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "zig", "fetch", "--save=spider", url },
        .cwd = .{ .dir = root_dir },
    });
    try wait(io, &child);
}

fn runShell(io: std.Io, root_dir: std.Io.Dir, script: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", script },
        .cwd = .{ .dir = root_dir },
    });
    try wait(io, &child);
}

fn wait(io: std.Io, child: *std.process.Child) !void {
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
}

const t = std.testing;

test "parseTarget: version, channels, mistakes" {
    try t.expect(try parseTarget(&.{}) == .latest);
    try t.expect(try parseTarget(&.{"--stable"}) == .latest);
    try t.expect(try parseTarget(&.{"--canary"}) == .canary);
    try t.expect(try parseTarget(&.{"--patch"}) == .patch);
    try t.expectEqualStrings("0.12.1", (try parseTarget(&.{"v0.12.1"})).version);
    try t.expectEqualStrings("0.12.1", (try parseTarget(&.{"0.12.1"})).version);
    try t.expectError(error.UnknownArgument, parseTarget(&.{"0.12"}));
    try t.expectError(error.UnknownArgument, parseTarget(&.{"0.12.1; rm -rf /"}));
    try t.expectError(error.TooManyArguments, parseTarget(&.{ "0.12.1", "x" }));
}

test "latestPatch and tagListed read git ls-remote --tags" {
    const out = "aaa\trefs/tags/v0.11.0\nbbb\trefs/tags/v0.12.0\nccc\trefs/tags/v0.12.1\nccd\trefs/tags/v0.12.1^{}\nddd\trefs/tags/v0.12.10\neee\trefs/tags/v0.13.0\nfff\trefs/tags/v0.12.2-rc1\n";
    try t.expectEqualStrings("0.12.10", latestPatch(out, "0.12").?);
    try t.expectEqualStrings("0.11.0", latestPatch(out, "0.11").?);
    try t.expect(latestPatch(out, "0.14") == null);
    try t.expect(tagListed(out, "v0.12.1"));
    try t.expect(!tagListed(out, "v0.12.3"));
}
