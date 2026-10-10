//! spider.testing.expectRoutes: a feature's access contract as a test.
//!
//! ```zig
//! test "posts routes: method, path and access" {
//!     try spider.testing.expectRoutes(routes.build(), &.{
//!         .{ "GET", "/posts", "roles:editor" },
//!         .{ "POST", "/posts/:id/delete", "roles:admin" },
//!     });
//! }
//! ```
//!
//! The access column is what `spider routes` prints: "public",
//! "roles:a,b", "org:a,b", "org:a roles:b", "authenticated", or "-"
//! (nothing declared), followed by " policy:name" when the route has a
//! policy (see `RouteMeta.writeAccess`). The
//! group must register exactly these routes (order doesn't matter), so a
//! route added, removed, moved or opened up fails `zig build test` until the
//! table is updated too — and that diff is what a reviewer reads.

const std = @import("std");
const Group = @import("group.zig").Group;
const Router = @import("router.zig").Router;

/// One expected route: the method in capitals ("GET"), the full path (group
/// prefix included, `:name` segments as registered), and the access column.
pub const Row = [3][]const u8;

/// Checks that `group` registers exactly the routes of `expected`, each
/// with that access; order does not matter. The access column is "public",
/// "roles:a,b", "org:a,b", "org:a roles:b", "authenticated" or "-" (nothing
/// declared), followed by " policy:name" when the route has a policy.
///
/// ```zig
/// test "posts routes: method, path and access" {
///     try spider.testing.expectRoutes(routes.build(), &.{
///         .{ "GET", "/posts", "roles:editor" },
///         .{ "POST", "/posts/:id/delete", "roles:admin" },
///     });
/// }
/// ```
///
/// On a difference it prints the routes missing and the routes not expected,
/// then the actual table ready to paste, and fails with `error.RoutesDiffer`.
pub fn expectRoutes(group: Group, expected: []const Row) !void {
    const gpa = std.heap.page_allocator;
    const list = try group.router.entries(gpa);
    defer Router.freeEntries(gpa, list);

    var actual: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (actual.items) |l| gpa.free(l);
        actual.deinit(gpa);
    }
    for (list) |e| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try e.route.meta.writeAccess(&aw.writer);
        try actual.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s} {s}", .{ @tagName(e.method), e.path, aw.written() }));
    }

    var wanted: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (wanted.items) |l| gpa.free(l);
        wanted.deinit(gpa);
    }
    for (expected) |r| try wanted.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s} {s}", .{ r[0], r[1], r[2] }));

    var problems: usize = 0;
    for (wanted.items) |w| if (!contains(actual.items, w)) {
        if (problems == 0) std.debug.print("\nroutes differ from the expected access table:\n", .{});
        problems += 1;
        std.debug.print("  expected, not registered:  {s}\n", .{w});
    };
    for (actual.items) |a| if (!contains(wanted.items, a)) {
        if (problems == 0) std.debug.print("\nroutes differ from the expected access table:\n", .{});
        problems += 1;
        std.debug.print("  registered, not expected:  {s}\n", .{a});
    };
    if (problems == 0) return;

    // The actual table, ready to paste once the change is intended.
    std.debug.print("actual table:\n", .{});
    for (list) |e| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try e.route.meta.writeAccess(&aw.writer);
        std.debug.print("    .{{ \"{s}\", \"{s}\", \"{s}\" }},\n", .{ @tagName(e.method), e.path, aw.written() });
    }
    return error.RoutesDiffer;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

const Ctx = @import("../core/context.zig").Ctx;
const Response = @import("../core/context.zig").Response;
fn ok(c: *Ctx) anyerror!Response {
    return c.text("ok", .{});
}

fn sample() Group {
    var g = Group.init("/posts");
    _ = g
        .defaults(.{ .roles = &.{"editor"} })
        .get("", ok, .{})
        .get("/:id", ok, .{ .public = true })
        .post("/:id/delete", ok, .{ .org_roles = &.{"admin"} });
    return g;
}

test "expectRoutes: passes on the exact table, in any order" {
    try expectRoutes(sample(), &.{
        .{ "POST", "/posts/:id/delete", "org:admin" },
        .{ "GET", "/posts", "roles:editor" },
        .{ "GET", "/posts/:id", "public" },
    });
}

test "expectRoutes: fails when a route's access changed" {
    try std.testing.expectError(error.RoutesDiffer, expectRoutes(sample(), &.{
        .{ "GET", "/posts", "-" },
        .{ "GET", "/posts/:id", "public" },
        .{ "POST", "/posts/:id/delete", "org:admin" },
    }));
}

test "expectRoutes: fails on a route added or missing" {
    try std.testing.expectError(error.RoutesDiffer, expectRoutes(sample(), &.{
        .{ "GET", "/posts", "roles:editor" },
        .{ "GET", "/posts/:id", "public" },
    }));
    try std.testing.expectError(error.RoutesDiffer, expectRoutes(sample(), &.{
        .{ "GET", "/posts", "roles:editor" },
        .{ "GET", "/posts/:id", "public" },
        .{ "POST", "/posts/:id/delete", "org:admin" },
        .{ "GET", "/posts/export", "roles:editor" },
    }));
}
