//! Which Spider a project is on, from how its build.zig.zon pins the
//! dependency, and the warning the CLI prints before working in a project
//! whose Spider is not the CLI's own: code the CLI writes follows its own
//! version and may not build on another one. Nobody has to move: the
//! warning says how to run the CLI that matches the project.

const std = @import("std");

/// How a project pins Spider.
pub const Pin = union(enum) {
    /// `?ref=vX.Y.Z`: a release (the version, without the `v`).
    release: []const u8,
    /// `?ref=<branch>` or `#<branch>`: a branch (develop, main, ...).
    branch: []const u8,
    /// `#<commit>`: a commit; its version is not known here.
    commit: []const u8,
    /// `.path = "..."`: a local checkout.
    path,
};

/// The pin of the `spider` dependency in a build.zig.zon text, or null when
/// the text has none.
pub fn pinOf(zon: []const u8) ?Pin {
    const at = std.mem.indexOf(u8, zon, ".spider = .{") orelse return null;
    const block_end = std.mem.indexOfPos(u8, zon, at, "}") orelse zon.len;
    const block = zon[at..block_end];
    if (std.mem.indexOf(u8, block, ".path") != null) return .path;
    const url_at = std.mem.indexOf(u8, block, ".url = \"") orelse return null;
    const url_start = url_at + ".url = \"".len;
    const url_end = std.mem.indexOfScalarPos(u8, block, url_start, '"') orelse return null;
    const url = block[url_start..url_end];
    if (std.mem.indexOf(u8, url, "?ref=")) |r| {
        const ref_start = r + "?ref=".len;
        const ref_end = std.mem.indexOfAnyPos(u8, url, ref_start, "#&") orelse url.len;
        const ref = url[ref_start..ref_end];
        if (ref.len > 1 and ref[0] == 'v' and std.ascii.isDigit(ref[1])) return .{ .release = ref[1..] };
        return .{ .branch = ref };
    }
    if (std.mem.lastIndexOfScalar(u8, url, '#')) |h| {
        const frag = url[h + 1 ..];
        for (frag) |c| if (!std.ascii.isHex(c)) return .{ .branch = frag };
        return .{ .commit = frag };
    }
    return null;
}

/// The warning for a project pinned with `pin` and a CLI of version
/// `cli` (like "0.12.1" or "0.13.0-dev"), or null when they match or the
/// project's version cannot be known (a local path, a commit).
pub fn warning(alc: std.mem.Allocator, cli: []const u8, pin: Pin) !?[]const u8 {
    const cli_dev = std.mem.indexOf(u8, cli, "-dev") != null;
    switch (pin) {
        .path, .commit => return null,
        .release => |v| {
            if (!cli_dev and std.mem.eql(u8, v, cli)) return null;
            return try std.fmt.allocPrint(alc,
                \\warning: this project uses Spider v{s}; this spider is v{s}.
                \\  Code it writes follows v{s} and may not build on v{s}. To use the
                \\  spider of the project's version:
                \\    curl -fsSL https://spiderme.org/install.sh | bash -s -- --version {s}
                \\  (or move the project with `spider update`)
                \\
            , .{ v, cli, cli, v, v });
        },
        .branch => |b| {
            const dev_branch = std.mem.eql(u8, b, "develop");
            if (dev_branch == cli_dev) return null;
            return try std.fmt.allocPrint(alc,
                \\warning: this project follows Spider's {s} branch; this spider is v{s}.
                \\  Code it writes follows v{s} and may not build there. Use the spider
                \\  built from that branch (zig build in a Spider checkout), or pin the
                \\  project to a release with `spider update`.
                \\
            , .{ b, cli, cli });
        },
    }
}

const t = std.testing;

test "pinOf: release, branch, commit, path" {
    const rel =
        \\.dependencies = .{
        \\    .spider = .{
        \\        .url = "git+https://github.com/llllOllOOll/spider?ref=v0.12.1#8452fdb0",
        \\        .hash = "spider-0.12.1-abc",
        \\    },
        \\},
    ;
    try t.expectEqualStrings("0.12.1", pinOf(rel).?.release);
    try t.expectEqualStrings("develop", pinOf(".spider = .{ .url = \"git+https://x/spider#develop\", }").?.branch);
    try t.expectEqualStrings("develop", pinOf(".spider = .{ .url = \"git+https://x/spider?ref=develop#9b96559\", }").?.branch);
    try t.expectEqualStrings("9b96559", pinOf(".spider = .{ .url = \"git+https://x/spider#9b96559\", }").?.commit);
    try t.expect(pinOf(".spider = .{ .path = \"../spider\", }").? == .path);
    try t.expect(pinOf(".dependencies = .{}") == null);
}

test "warning: only when the project's version is known and differs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect((try warning(a, "0.12.1", .{ .release = "0.12.1" })) == null);
    try t.expect((try warning(a, "0.13.0-dev", .{ .branch = "develop" })) == null);
    try t.expect((try warning(a, "0.13.0-dev", .path)) == null);
    try t.expect((try warning(a, "0.12.1", .{ .commit = "9b96559" })) == null);
    const w = (try warning(a, "0.13.0", .{ .release = "0.12.1" })).?;
    try t.expect(std.mem.indexOf(u8, w, "uses Spider v0.12.1; this spider is v0.13.0") != null);
    try t.expect(std.mem.indexOf(u8, w, "--version 0.12.1") != null);
    try t.expect((try warning(a, "0.13.0-dev", .{ .release = "0.12.1" })) != null);
    try t.expect((try warning(a, "0.12.1", .{ .branch = "develop" })) != null);
}
