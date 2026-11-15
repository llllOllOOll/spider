//! Internal: template paths written the same way on every system.

/// `path` with its separator `sep` replaced by '/', in `buffer` (as long as
/// `path`). On systems whose separator is already '/', `path` itself: there
/// a '\' is an ordinary character of a file name.
pub fn slashPath(path: []const u8, sep: u8, buffer: []u8) []const u8 {
    if (sep == '/') return path;
    const out = buffer[0..path.len];
    for (path, out) |ch, *o| o.* = if (ch == sep) '/' else ch;
    return out;
}

const std = @import("std");

test "slashPath turns the given separator into '/'" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a/b/c.html", slashPath("a\\b\\c.html", '\\', &buf));
}

test "slashPath keeps a backslash when the separator is '/'" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("odd\\name.html", slashPath("odd\\name.html", '/', &buf));
}
