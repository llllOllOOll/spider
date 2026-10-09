const std = @import("std");
const router_mod = @import("router.zig");
const Router = router_mod.Router;
const Route = router_mod.Route;
const Group = @import("group.zig").Group;
const ctx_mod = @import("../core/context.zig");
const Ctx = ctx_mod.Ctx;
const Response = ctx_mod.Response;
const NextFn = ctx_mod.NextFn;
const MiddlewareFn = ctx_mod.MiddlewareFn;
const rbac = @import("../modules/rbac.zig");

fn h1(c: *Ctx) anyerror!Response {
    return c.text("h1", .{});
}
fn h2(c: *Ctx) anyerror!Response {
    return c.text("h2", .{});
}
fn mwA(c: *Ctx, next: NextFn) anyerror!Response {
    return next(c);
}
fn mwB(c: *Ctx, next: NextFn) anyerror!Response {
    return next(c);
}

const mws_a = [_]MiddlewareFn{mwA};
const mws_ab = [_]MiddlewareFn{ mwA, mwB };

fn expectMws(expected: []const MiddlewareFn, actual: []const MiddlewareFn) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try std.testing.expect(e == a);
}

test "router: static route match carries its middlewares" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try Router.init(std.testing.allocator);
    defer r.deinit();

    try r.addRoute(.GET, "/admin", .{ .handler = h1, .middlewares = &mws_a });
    const m = (try r.match(.GET, "/admin", arena.allocator())).?;
    try std.testing.expect(m.handler == h1);
    try expectMws(&mws_a, m.middlewares);
}

test "router: :param route match carries its middlewares" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try Router.init(std.testing.allocator);
    defer r.deinit();

    try r.addRoute(.GET, "/items/:id", .{ .handler = h1, .middlewares = &mws_ab });
    const m = (try r.match(.GET, "/items/42", arena.allocator())).?;
    try expectMws(&mws_ab, m.middlewares);
    try std.testing.expectEqualStrings("42", m.params.get("id").?);
}

test "router: wildcard route match carries its middlewares" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try Router.init(std.testing.allocator);
    defer r.deinit();

    try r.addRoute(.GET, "/files/*", .{ .handler = h1, .middlewares = &mws_a });
    const m = (try r.match(.GET, "/files/a.pdf", arena.allocator())).?;
    try expectMws(&mws_a, m.middlewares);
}

test "router: middlewares are per method on the same path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try Router.init(std.testing.allocator);
    defer r.deinit();

    try r.addRoute(.GET, "/items/:id", .{ .handler = h1 });
    try r.addRoute(.POST, "/items/:id", .{ .handler = h2, .middlewares = &mws_a });

    const g = (try r.match(.GET, "/items/1", arena.allocator())).?;
    try std.testing.expectEqual(@as(usize, 0), g.middlewares.len);
    const p = (try r.match(.POST, "/items/1", arena.allocator())).?;
    try std.testing.expect(p.handler == h2);
    try expectMws(&mws_a, p.middlewares);
}

test "router: static sibling does not inherit dynamic route middlewares" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try Router.init(std.testing.allocator);
    defer r.deinit();

    try r.addRoute(.GET, "/users/new", .{ .handler = h1 });
    try r.addRoute(.GET, "/users/:id", .{ .handler = h2, .middlewares = &mws_a });

    const s = (try r.match(.GET, "/users/new", arena.allocator())).?;
    try std.testing.expect(s.handler == h1);
    try std.testing.expectEqual(@as(usize, 0), s.middlewares.len);
    const d = (try r.match(.GET, "/users/7", arena.allocator())).?;
    try std.testing.expect(d.handler == h2);
    try expectMws(&mws_a, d.middlewares);
}

test "router: add() keeps working and registers no middlewares" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try Router.init(std.testing.allocator);
    defer r.deinit();

    try r.add(.GET, "/plain/:id", h1);
    const m = (try r.match(.GET, "/plain/1", arena.allocator())).?;
    try std.testing.expectEqual(@as(usize, 0), m.middlewares.len);
}

test "router: re-registering a static route replaces it without leaking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try Router.init(std.testing.allocator);
    defer r.deinit();

    try r.addRoute(.GET, "/x", .{ .handler = h1 });
    try r.addRoute(.GET, "/x", .{ .handler = h2, .middlewares = &mws_a });
    const m = (try r.match(.GET, "/x", arena.allocator())).?;
    try std.testing.expect(m.handler == h2);
    try expectMws(&mws_a, m.middlewares);
}

const Collected = struct {
    count: usize = 0,
    with_mws: usize = 0,
};

fn collect(c: *Collected, _: std.http.Method, _: []const u8, route: Route) void {
    c.count += 1;
    if (route.middlewares.len > 0) c.with_mws += 1;
}

test "router: forEach exposes middlewares so mount() can carry them over" {
    var r = try Router.init(std.testing.allocator);
    defer r.deinit();

    try r.addRoute(.GET, "/a", .{ .handler = h1, .middlewares = &mws_a });
    try r.addRoute(.GET, "/b/:id", .{ .handler = h1, .middlewares = &mws_a });
    try r.addRoute(.GET, "/c", .{ .handler = h1 });

    var c: Collected = .{};
    r.forEach(std.testing.allocator, &c, collect);
    try std.testing.expectEqual(@as(usize, 3), c.count);
    try std.testing.expectEqual(@as(usize, 2), c.with_mws);
}

test "rbac.routeMiddlewares: empty config -> no middlewares" {
    try std.testing.expectEqual(@as(usize, 0), rbac.routeMiddlewares(.{}).len);
    try std.testing.expectEqual(@as(usize, 0), rbac.routeMiddlewares(.{ .roles = &[_][]const u8{} }).len);
}

test "rbac.routeMiddlewares: roles and org_roles each add one middleware" {
    const admin = &[_][]const u8{"admin"};
    try std.testing.expectEqual(@as(usize, 1), rbac.routeMiddlewares(.{ .roles = admin }).len);
    try std.testing.expectEqual(@as(usize, 1), rbac.routeMiddlewares(.{ .org_roles = admin }).len);
    try std.testing.expectEqual(@as(usize, 2), rbac.routeMiddlewares(.{ .roles = admin, .org_roles = admin }).len);
}

test "Group: routes with RBAC config carry middlewares in the group router" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var g = Group.init("/api");
    _ = g
        .get("/items/:id", h1, .{ .roles = &[_][]const u8{"admin"} })
        .post("/items", h2, .{});

    const m = (try g.router.match(.GET, "/api/items/5", arena.allocator())).?;
    try std.testing.expectEqual(@as(usize, 1), m.middlewares.len);
    const p = (try g.router.match(.POST, "/api/items", arena.allocator())).?;
    try std.testing.expectEqual(@as(usize, 0), p.middlewares.len);
}

test "RouteMeta.writeAccess: the access column of the route listing" {
    const cases = [_]struct { router_mod.RouteMeta, []const u8 }{
        .{ .{}, "-" },
        .{ .{ .public = true }, "public" },
        .{ .{ .roles = &.{ "a", "b" } }, "roles:a,b" },
        .{ .{ .org_roles = &.{"admin"} }, "org:admin" },
        .{ .{ .org_roles = &.{"admin"}, .roles = &.{"staff"} }, "org:admin roles:staff" },
        .{ .{ .quiet_log = true }, "-" },
        .{ .{ .authenticated = true }, "authenticated" },
        .{ .{ .authenticated = true, .roles = &.{"a"} }, "roles:a" },
        .{ .{ .policy = "post_owner" }, "policy:post_owner" },
        .{ .{ .roles = &.{"staff"}, .policy = "post_owner" }, "roles:staff policy:post_owner" },
        .{ .{ .authenticated = true, .policy = "post_owner" }, "authenticated policy:post_owner" },
        .{ .{ .public = true, .policy = "stripe_signature" }, "public policy:stripe_signature" },
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try c[0].writeAccess(&w);
        try std.testing.expectEqualStrings(c[1], w.buffered());
        try std.testing.expectEqual(!std.mem.eql(u8, c[1], "-"), c[0].declaresAccess());
    }
}

test "Router.entries: every route once, sorted by path then method, with its meta" {
    var r = try Router.init(std.testing.allocator);
    defer r.deinit();
    try r.addRoute(.POST, "/b", .{ .handler = h1 });
    try r.addRoute(.GET, "/b", .{ .handler = h1, .meta = .{ .public = true } });
    try r.addRoute(.GET, "/a/:id", .{ .handler = h2 });
    try r.addRoute(.GET, "/a", .{ .handler = h2 });
    const list = try r.entries(std.testing.allocator);
    defer Router.freeEntries(std.testing.allocator, list);
    try std.testing.expectEqual(@as(usize, 4), list.len);
    try std.testing.expectEqualStrings("/a", list[0].path);
    try std.testing.expectEqualStrings("/a/:id", list[1].path);
    try std.testing.expectEqualStrings("/b", list[2].path);
    try std.testing.expectEqual(std.http.Method.GET, list[2].method);
    try std.testing.expect(list[2].route.meta.public);
    try std.testing.expectEqual(std.http.Method.POST, list[3].method);
}

test "router: two routes may name the param at the same position differently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try Router.init(std.testing.allocator);
    defer r.deinit();

    try r.addRoute(.GET, "/posts/:author", .{ .handler = h1 });
    try r.addRoute(.POST, "/posts/:id", .{ .handler = h2 });
    try r.addRoute(.GET, "/posts/:id/comments/:comment", .{ .handler = h2 });

    const by_author = (try r.match(.GET, "/posts/ana", arena.allocator())).?;
    try std.testing.expectEqualStrings("ana", by_author.params.get("author").?);
    try std.testing.expect(by_author.params.get("id") == null);

    const by_id = (try r.match(.POST, "/posts/7", arena.allocator())).?;
    try std.testing.expectEqualStrings("7", by_id.params.get("id").?);
    try std.testing.expect(by_id.params.get("author") == null);

    const nested = (try r.match(.GET, "/posts/7/comments/3", arena.allocator())).?;
    try std.testing.expectEqualStrings("7", nested.params.get("id").?);
    try std.testing.expectEqualStrings("3", nested.params.get("comment").?);
}

const Paths = struct {
    seen: [3]bool = @splat(false),
    fn cb(self: *Paths, method: std.http.Method, path: []const u8, _: Route) void {
        const wanted = [_]struct { std.http.Method, []const u8 }{
            .{ .GET, "/posts/:author" },
            .{ .POST, "/posts/:id" },
            .{ .GET, "/posts/:id/comments/:comment" },
        };
        for (wanted, 0..) |w, i| {
            if (w[0] == method and std.mem.eql(u8, w[1], path)) self.seen[i] = true;
        }
    }
};

test "router: forEach lists each route with its own param names" {
    var r = try Router.init(std.testing.allocator);
    defer r.deinit();

    try r.addRoute(.GET, "/posts/:author", .{ .handler = h1 });
    try r.addRoute(.POST, "/posts/:id", .{ .handler = h2 });
    try r.addRoute(.GET, "/posts/:id/comments/:comment", .{ .handler = h2 });

    var paths: Paths = .{};
    r.forEach(std.testing.allocator, &paths, Paths.cb);
    for (paths.seen) |seen| try std.testing.expect(seen);
}
