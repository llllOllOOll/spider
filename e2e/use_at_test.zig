// End-to-end tests for server.useAt: which addresses a middleware given for
// a path runs on.

const std = @import("std");
const spider = @import("spider");

fn page(c: *spider.Ctx) !spider.Response {
    return c.text("page", .{});
}

/// Stands for "you must be signed in": refuses everything it runs on.
fn guard(_: *spider.Ctx, _: spider.NextFn) !spider.Response {
    return error.Forbidden;
}

fn run() !void {
    var server = spider.app(.{});
    defer server.deinit();
    var group = spider.Group.init("/team");
    _ = group
        .defaults(.{ .public = true })
        .useAt("/private", guard)
        .get("", page, .{})
        .get("/private", page, .{})
        .get("/private/notes", page, .{})
        .get("/privateer", page, .{});
    try server
        .useAt("/admin", guard)
        .useAt("/panel/*", guard)
        .useAt("/files/", guard)
        .get("/admin", page, .{ .public = true })
        .get("/admin/users", page, .{ .public = true })
        .get("/admin/users/:id", page, .{ .public = true })
        .get("/administrators", page, .{ .public = true })
        .get("/admin-old", page, .{ .public = true })
        .get("/panel", page, .{ .public = true })
        .get("/panel/stats", page, .{ .public = true })
        .get("/panels", page, .{ .public = true })
        .get("/files", page, .{ .public = true })
        .get("/files/a", page, .{ .public = true })
        .get("/other", page, .{ .public = true })
        .mount(group)
        .listen(.{});
}

fn status(app: spider.testing.App, target: []const u8) !u16 {
    var res = try app.get(target);
    defer res.deinit();
    return res.status;
}

test "useAt: a path covers itself and what is under it, and nothing that only starts like it" {
    const app = try spider.testing.start(run);

    // The path itself, and everything below.
    try std.testing.expectEqual(@as(u16, 403), try status(app, "/admin"));
    try std.testing.expectEqual(@as(u16, 403), try status(app, "/admin/users"));
    try std.testing.expectEqual(@as(u16, 403), try status(app, "/admin/users/7"));
    try std.testing.expectEqual(@as(u16, 403), try status(app, "/admin?tab=1"));
    // Another address that begins with the same letters is not under it.
    try std.testing.expectEqual(@as(u16, 200), try status(app, "/administrators"));
    try std.testing.expectEqual(@as(u16, 200), try status(app, "/admin-old"));
    try std.testing.expectEqual(@as(u16, 200), try status(app, "/other"));
}

test "useAt: \"/panel/*\" and \"/files/\" mean the same as \"/panel\" and \"/files\"" {
    const app = try spider.testing.start(run);

    // The page a guard written with /* is most often meant to cover.
    try std.testing.expectEqual(@as(u16, 403), try status(app, "/panel"));
    try std.testing.expectEqual(@as(u16, 403), try status(app, "/panel/stats"));
    try std.testing.expectEqual(@as(u16, 200), try status(app, "/panels"));

    try std.testing.expectEqual(@as(u16, 403), try status(app, "/files"));
    try std.testing.expectEqual(@as(u16, 403), try status(app, "/files/a"));
}

test "useAt on a group: the same rule under the group's prefix" {
    const app = try spider.testing.start(run);

    try std.testing.expectEqual(@as(u16, 200), try status(app, "/team"));
    try std.testing.expectEqual(@as(u16, 403), try status(app, "/team/private"));
    try std.testing.expectEqual(@as(u16, 403), try status(app, "/team/private/notes"));
    try std.testing.expectEqual(@as(u16, 200), try status(app, "/team/privateer"));
}
