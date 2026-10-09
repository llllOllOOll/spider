const std = @import("std");
const fs_utils = @import("fs_utils.zig");

pub fn updateFeaturesMod(io: std.Io, allocator: std.mem.Allocator, features_dir: std.Io.Dir, feature: []const u8) !void {
    const mod_path = "mod.zig";

    const existing = features_dir.readFileAlloc(io, mod_path, allocator, .limited(64 * 1024)) catch "";
    defer if (existing.len > 0) allocator.free(existing);

    const new_content = try withFeature(allocator, existing, feature);
    defer allocator.free(new_content);

    try fs_utils.writeFile(io, features_dir, mod_path, new_content);
}

/// `existing` with the feature's `pub const` line added after the last one
/// already there (or first, in a file with none), so the list stays at the
/// top, above the tests.
pub fn withFeature(allocator: std.mem.Allocator, existing: []const u8, feature: []const u8) ![]u8 {
    const new_line = try std.fmt.allocPrint(allocator, "pub const {s} = @import(\"{s}/mod.zig\");\n", .{ feature, feature });
    defer allocator.free(new_line);

    var insert_at: usize = 0;
    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        offset += line.len + 1;
        if (std.mem.startsWith(u8, line, "pub const ") and std.mem.endsWith(u8, std.mem.trimEnd(u8, line, " \r"), "/mod.zig\");")) {
            insert_at = @min(offset, existing.len);
        }
    }
    const needs_newline = insert_at > 0 and existing[insert_at - 1] != '\n';
    return std.mem.concat(allocator, u8, &.{
        existing[0..insert_at],
        if (needs_newline) "\n" else "",
        new_line,
        existing[insert_at..],
    });
}

test "withFeature: the new line joins the list at the top" {
    const a = std.testing.allocator;
    const out = try withFeature(a,
        \\pub const home = @import("home/mod.zig");
        \\
        \\// tests below
        \\test {
        \\    @import("std").testing.refAllDecls(@This());
        \\}
        \\
    , "posts");
    defer a.free(out);
    try std.testing.expectEqualStrings(
        \\pub const home = @import("home/mod.zig");
        \\pub const posts = @import("posts/mod.zig");
        \\
        \\// tests below
        \\test {
        \\    @import("std").testing.refAllDecls(@This());
        \\}
        \\
    , out);
}

test "withFeature: a file with no feature yet, and one without a final newline" {
    const a = std.testing.allocator;
    const first = try withFeature(a, "// no features yet\n", "posts");
    defer a.free(first);
    try std.testing.expectEqualStrings("pub const posts = @import(\"posts/mod.zig\");\n// no features yet\n", first);

    const second = try withFeature(a, "pub const home = @import(\"home/mod.zig\");", "posts");
    defer a.free(second);
    try std.testing.expectEqualStrings("pub const home = @import(\"home/mod.zig\");\npub const posts = @import(\"posts/mod.zig\");\n", second);
}
