//! Wires a generated feature into src/main.zig.
//!
//! The feature's routes live in src/features/<name>/routes.zig. Apps whose
//! main.zig calls `server.mountFeatures(features)` pick them up through
//! src/features/mod.zig, so main.zig is left alone. Apps generated before
//! that list routes in main.zig; there `.mountFeature(features.<name>)` is
//! inserted before `.onError(`. Anything else is left to the developer.

const std = @import("std");
const fs_utils = @import("fs_utils.zig");

pub const Plan = union(enum) {
    /// main.zig calls mountFeatures(features): nothing to change.
    automatic,
    /// Insert the mountFeature line at this offset (start of the .onError line).
    insert_at: usize,
    /// No marker found: print what to add by hand.
    manual,
};

const features_import = "const features = @import(\"features\");";
const onerror_marker = "        .onError(";

pub fn plan(main_src: []const u8) Plan {
    if (std.mem.indexOf(u8, main_src, ".mountFeatures(features)") != null) return .automatic;
    if (std.mem.indexOf(u8, main_src, features_import) == null) return .manual;
    const pos = std.mem.indexOf(u8, main_src, onerror_marker) orelse return .manual;
    return .{ .insert_at = pos };
}

pub fn mountLine(allocator: std.mem.Allocator, feature: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "        .mountFeature(features.{s})\n", .{feature});
}

/// What happened, for the generator's output.
pub const Outcome = enum { automatic, inserted, manual, no_main };

pub fn wireFeature(io: std.Io, allocator: std.mem.Allocator, root_dir: std.Io.Dir, feature: []const u8) !Outcome {
    const main_path = "src/main.zig";
    const existing = root_dir.readFileAlloc(io, main_path, allocator, .limited(64 * 1024)) catch return .no_main;
    defer allocator.free(existing);

    switch (plan(existing)) {
        .automatic => return .automatic,
        .manual => return .manual,
        .insert_at => |pos| {
            const line = try mountLine(allocator, feature);
            defer allocator.free(line);
            const updated = try std.mem.concat(allocator, u8, &.{ existing[0..pos], line, existing[pos..] });
            defer allocator.free(updated);
            try fs_utils.writeFile(io, root_dir, main_path, updated);
            return .inserted;
        },
    }
}

const t = std.testing;

test "plan: mountFeatures apps need no change" {
    try t.expectEqual(Plan.automatic, plan(
        \\const features = @import("features");
        \\    server
        \\        .mountFeatures(features)
        \\        .onError(spider.errorHandler(.{}))
    ));
}

test "plan: older apps get mountFeature before .onError(" {
    const src =
        \\const features = @import("features");
        \\    server
        \\        .get("/", home.controller.index, .{})
        \\        .onError(errorHandler)
    ;
    const p = plan(src);
    try t.expect(p == .insert_at);
    try t.expect(std.mem.startsWith(u8, src[p.insert_at..], "        .onError("));
    const line = try mountLine(t.allocator, "posts");
    defer t.allocator.free(line);
    try t.expectEqualStrings("        .mountFeature(features.posts)\n", line);
}

test "plan: without the features import or .onError( it's manual" {
    try t.expectEqual(Plan.manual, plan("    server\n        .onError(errorHandler)\n"));
    try t.expectEqual(Plan.manual, plan("const features = @import(\"features\");\n    server.listen(.{});\n"));
}
