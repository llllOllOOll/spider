//! The version of this Spider, as code. Modules compare it with the range of
//! Spider versions they support (`spider.module`). `zig build test` fails
//! when it differs from the `.version` of `build.zig.zon`
//! (src/version_check_tool.zig): a release changes both.

const std = @import("std");

/// The version of this Spider, as text: the same as `build.zig.zon`.
pub const string = "0.11.0-dev.1";

/// The version of this Spider: `spider.version.major`, `.minor`, `.patch`.
///
/// ```zig
/// if (spider.version.order(try std.SemanticVersion.parse("0.11.0")) == .lt) {
///     // an older Spider
/// }
/// ```
pub const version: std.SemanticVersion = std.SemanticVersion.parse(string) catch unreachable;

// internal: the `.version = "..."` of a build.zig.zon text, for the check
// that keeps `string` equal to it; null when the text has none.
pub fn zonVersion(text: []const u8) ?[]const u8 {
    var rest = text;
    while (std.mem.indexOf(u8, rest, ".version")) |at| {
        var i = at + ".version".len;
        rest = text[i..];
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        if (i >= text.len or text[i] != '=') continue;
        i += 1;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        if (i >= text.len or text[i] != '"') continue;
        const start = i + 1;
        const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse return null;
        return text[start..end];
    }
    return null;
}

test "zonVersion: the package's version, not a dependency's or a minimum one" {
    const zon =
        \\.{
        \\    .name = .spider,
        \\    .version = "0.10.1",
        \\    .minimum_zig_version = "0.17.0",
        \\}
    ;
    try std.testing.expectEqualStrings("0.10.1", zonVersion(zon).?);
    try std.testing.expect(zonVersion(".{ .name = .x }") == null);
    try std.testing.expectEqualStrings("1.2.3", zonVersion(".{ .version=\"1.2.3\" }").?);
}

test "version: parsed from string" {
    try std.testing.expectEqual(@as(usize, 0), version.major);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings(string, try std.fmt.bufPrint(&buf, "{f}", .{version}));
}
