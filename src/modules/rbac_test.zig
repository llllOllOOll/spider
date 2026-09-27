const std = @import("std");
const ctx_mod = @import("../core/context.zig");
const Ctx = ctx_mod.Ctx;
const Response = ctx_mod.Response;
const rbac = @import("rbac.zig");

const OrgRole = struct { id: []const u8, role: []const u8 };

/// Builds a Ctx carrying the same `_auth_*` params the JWKS provider injects.
fn makeCtx(alc: std.mem.Allocator, realm_roles: []const []const u8, orgs: []const OrgRole) !Ctx {
    var c = Ctx{ .request = undefined, .arena = alc, .params = .{}, .body = null };
    for (realm_roles, 0..) |r, i| {
        try c.params.put(alc, try std.fmt.allocPrint(alc, "_auth_role_{d}", .{i}), r);
    }
    try c.params.put(alc, "_auth_roles_count", try std.fmt.allocPrint(alc, "{d}", .{realm_roles.len}));
    for (orgs, 0..) |o, i| {
        try c.params.put(alc, try std.fmt.allocPrint(alc, "_auth_org_{d}_id", .{i}), o.id);
        try c.params.put(alc, try std.fmt.allocPrint(alc, "_auth_org_{d}_role", .{i}), o.role);
    }
    try c.params.put(alc, "_auth_orgs_count", try std.fmt.allocPrint(alc, "{d}", .{orgs.len}));
    return c;
}

fn passThrough(c: *Ctx) anyerror!Response {
    return c.text("next", .{});
}

/// Runs `mw` and reports whether it let the request through.
fn allows(mw: ctx_mod.MiddlewareFn, c: *Ctx) !bool {
    _ = mw(c, passThrough) catch |err| switch (err) {
        error.Forbidden => return false,
        else => return err,
    };
    return true;
}

const admin_only = &[_][]const u8{"admin"};
const admin_or_council = &[_][]const u8{ "admin", "council" };

// admin in org A, resident in org B — the exact shape of the reported bug.
const two_orgs = [_]OrgRole{
    .{ .id = "orgA", .role = "admin" },
    .{ .id = "orgB", .role = "resident" },
};

test "requireOrgRoles: active org without the role is denied even if another org has it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = try makeCtx(arena.allocator(), &.{}, &two_orgs);
    try c.setActiveOrg("orgB");
    try std.testing.expect(!try allows(rbac.requireOrgRoles(admin_only), &c));
}

test "requireOrgRoles: active org with the role is allowed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = try makeCtx(arena.allocator(), &.{}, &two_orgs);
    try c.setActiveOrg("orgA");
    try std.testing.expect(try allows(rbac.requireOrgRoles(admin_only), &c));
}

test "requireOrgRoles: active org the user does not belong to is denied" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = try makeCtx(arena.allocator(), &.{}, &two_orgs);
    try c.setActiveOrg("orgZ");
    try std.testing.expect(!try allows(rbac.requireOrgRoles(admin_only), &c));
}

test "requireOrgRoles: no active org falls back to any org" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = try makeCtx(arena.allocator(), &.{}, &two_orgs);
    try std.testing.expect(try allows(rbac.requireOrgRoles(admin_only), &c));
    try std.testing.expect(!try allows(rbac.requireOrgRoles(&[_][]const u8{"vendor"}), &c));
}

test "requireOrgRoles: several roles in the same active org, any listed role passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const orgs = [_]OrgRole{
        .{ .id = "orgA", .role = "resident" },
        .{ .id = "orgA", .role = "council" },
        .{ .id = "orgB", .role = "admin" },
    };
    var c = try makeCtx(arena.allocator(), &.{}, &orgs);
    try c.setActiveOrg("orgA");
    try std.testing.expect(try allows(rbac.requireOrgRoles(admin_or_council), &c));
    try std.testing.expect(!try allows(rbac.requireOrgRoles(admin_only), &c));
}

test "requireOrgRoles: no org claims at all is denied" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = Ctx{ .request = undefined, .arena = arena.allocator(), .params = .{}, .body = null };
    try std.testing.expect(!try allows(rbac.requireOrgRoles(admin_only), &c));
    try c.setActiveOrg("orgA");
    try std.testing.expect(!try allows(rbac.requireOrgRoles(admin_only), &c));
}

test "requireOrgRoles: malformed org count is denied, not crashed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = Ctx{ .request = undefined, .arena = arena.allocator(), .params = .{}, .body = null };
    try c.params.put(arena.allocator(), "_auth_orgs_count", "not-a-number");
    try std.testing.expect(!try allows(rbac.requireOrgRoles(admin_only), &c));
}

test "requireRoles: realm role check is unaffected by the active org" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = try makeCtx(arena.allocator(), &.{"admin"}, &two_orgs);
    try c.setActiveOrg("orgB");
    try std.testing.expect(try allows(rbac.requireRoles(admin_only), &c));
    try std.testing.expect(!try allows(rbac.requireRoles(&[_][]const u8{"root"}), &c));
}

test "Ctx.activeOrgId / hasActiveOrgRole / hasOrgRole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = try makeCtx(arena.allocator(), &.{}, &two_orgs);

    try std.testing.expect(c.activeOrgId() == null);
    try std.testing.expect(c.hasActiveOrgRole("admin")); // no selection -> any org
    try std.testing.expect(c.hasOrgRole("admin"));

    try c.setActiveOrg("orgB");
    try std.testing.expectEqualStrings("orgB", c.activeOrgId().?);
    try std.testing.expect(!c.hasActiveOrgRole("admin"));
    try std.testing.expect(c.hasActiveOrgRole("resident"));
    // hasOrgRole keeps its documented "any org" meaning.
    try std.testing.expect(c.hasOrgRole("admin"));
}

test "rbac.routeMiddlewares: roles + org_roles route needs both" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const mws = rbac.routeMiddlewares(.{ .roles = &[_][]const u8{"staff"}, .org_roles = admin_only });

    var only_realm = try makeCtx(arena.allocator(), &.{"staff"}, &.{});
    var only_org = try makeCtx(arena.allocator(), &.{}, &two_orgs);
    var both = try makeCtx(arena.allocator(), &.{"staff"}, &two_orgs);

    try std.testing.expect(try allows(mws[0], &only_realm));
    try std.testing.expect(!try allows(mws[1], &only_realm));
    try std.testing.expect(!try allows(mws[0], &only_org));
    try std.testing.expect(try allows(mws[0], &both));
    try std.testing.expect(try allows(mws[1], &both));
}

test "Ctx.isOrgMember" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = try makeCtx(arena.allocator(), &.{}, &two_orgs);
    try std.testing.expect(c.isOrgMember("orgA"));
    try std.testing.expect(c.isOrgMember("orgB"));
    try std.testing.expect(!c.isOrgMember("orgZ"));
    var none = Ctx{ .request = undefined, .arena = arena.allocator(), .params = .{}, .body = null };
    try std.testing.expect(!none.isOrgMember("orgA"));
}

fn bareCtx(alc: std.mem.Allocator) Ctx {
    return Ctx{ .request = undefined, .arena = alc, .params = .{}, .body = null };
}

/// Runs `mw`, returning the error it failed with (null when it let the request through).
fn failure(mw: ctx_mod.MiddlewareFn, c: *Ctx) ?anyerror {
    _ = mw(c, passThrough) catch |err| return err;
    return null;
}

test "Ctx.addRole / setRoles: roles from any source feed .roles checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = bareCtx(arena.allocator());
    try std.testing.expect(!try allows(rbac.requireRoles(&.{"editor"}), &c));
    try c.addRole("viewer");
    try c.addRole("editor");
    try std.testing.expect(c.hasRole("viewer") and c.hasRole("editor"));
    try std.testing.expect(try allows(rbac.requireRoles(&.{"editor"}), &c));
    const listed = try c.roles();
    try std.testing.expectEqual(@as(usize, 2), listed.len);
    try std.testing.expectEqualStrings("editor", listed[1]);

    try c.setRoles(&.{"viewer"});
    try std.testing.expect(!c.hasRole("editor"));
    try std.testing.expect(!try allows(rbac.requireRoles(&.{"editor"}), &c));
    try std.testing.expectEqual(@as(usize, 1), (try c.roles()).len);
}

test "Ctx.addOrgRole: feeds .org_roles and writes the same _auth_org_N_* params the JWKS provider does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = bareCtx(arena.allocator());
    try c.addOrgRole(.{ .org_id = "c1", .org_name = "Tower A", .role = "manager" });
    try c.addOrgRole(.{ .org_id = "c2", .role = "resident" });
    try std.testing.expectEqualStrings("2", c.params.get("_auth_orgs_count").?);
    try std.testing.expectEqualStrings("c1", c.params.get("_auth_org_0_id").?);
    try std.testing.expectEqualStrings("Tower A", c.params.get("_auth_org_0_name").?);
    try std.testing.expectEqualStrings("manager", c.params.get("_auth_org_0_role").?);
    try std.testing.expectEqualStrings("", c.params.get("_auth_org_1_name").?);
    try std.testing.expect(c.isOrgMember("c2"));
    try std.testing.expect(try allows(rbac.requireOrgRoles(&.{"manager"}), &c));
    try c.setActiveOrg("c2");
    try std.testing.expect(!try allows(rbac.requireOrgRoles(&.{"manager"}), &c));
}

test "Ctx.setUser / userId: an app's own login satisfies .authenticated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = bareCtx(arena.allocator());
    try std.testing.expect(c.userId() == null);
    try std.testing.expectEqual(@as(?anyerror, error.Unauthorized), failure(rbac.requireAuthenticated, &c));
    try c.setUser(.{ .id = "42", .email = "a@b.c" });
    try std.testing.expectEqualStrings("42", c.userId().?);
    try std.testing.expectEqualStrings("a@b.c", c.params.get("_auth_email").?);
    try std.testing.expect(c.params.get("_auth_name") == null);
    try std.testing.expectEqual(@as(?anyerror, null), failure(rbac.requireAuthenticated, &c));

    // The HS256 `auth` middleware's identity counts too.
    var h = bareCtx(arena.allocator());
    try h.params.put(arena.allocator(), "_user_id", "7");
    try std.testing.expectEqualStrings("7", h.userId().?);
}

fn isOwner(c: *Ctx) anyerror!bool {
    return std.mem.eql(u8, c.params.get("owner") orelse "", c.userId() orelse "-");
}
fn alwaysTrue(c: *Ctx) bool {
    _ = c;
    return true;
}
fn broken(c: *Ctx) anyerror!bool {
    _ = c;
    return error.DatabaseDown;
}

test "policy: true passes; false is 403 with a user, 401 without one; errors propagate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const owner = rbac.requirePolicy(rbac.policy("post_owner", isOwner));

    var anon = bareCtx(a);
    try std.testing.expectEqual(@as(?anyerror, error.Unauthorized), failure(owner, &anon));

    var other = bareCtx(a);
    try other.setUser(.{ .id = "1" });
    try other.params.put(a, "owner", "2");
    try std.testing.expectEqual(@as(?anyerror, error.Forbidden), failure(owner, &other));

    var same = bareCtx(a);
    try same.setUser(.{ .id = "2" });
    try same.params.put(a, "owner", "2");
    try std.testing.expectEqual(@as(?anyerror, null), failure(owner, &same));

    // A check that can't fail returns plain bool.
    var anyone = bareCtx(a);
    try std.testing.expectEqual(@as(?anyerror, null), failure(rbac.requirePolicy(rbac.policy("open", alwaysTrue)), &anyone));
    try std.testing.expectEqual(@as(?anyerror, error.DatabaseDown), failure(rbac.requirePolicy(rbac.policy("db", broken)), &anyone));
}

test "rbac.routeMiddlewares: the policy runs after roles and org_roles" {
    const mws = comptime rbac.routeMiddlewares(.{ .roles = &[_][]const u8{"staff"}, .policy = rbac.policy("post_owner", isOwner) });
    try std.testing.expectEqual(@as(usize, 2), mws.len);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = bareCtx(arena.allocator());
    try c.setUser(.{ .id = "2" });
    try c.params.put(arena.allocator(), "owner", "2");
    try std.testing.expectEqual(@as(?anyerror, error.Forbidden), failure(mws[0], &c)); // no staff role
    try std.testing.expectEqual(@as(?anyerror, null), failure(mws[1], &c));
}

// --- resourcePolicy ----------------------------------------------------------

const Post = struct { id: u32, owner: []const u8, title: []const u8 };
const Other = struct { x: u8 };

var load_calls: usize = 0;

/// Posts 10 (user 1's) and 11 (user 2's); anything else doesn't exist.
fn loadPost(c: *Ctx) !?Post {
    load_calls += 1;
    const id = std.fmt.parseInt(u32, c.params.get("id") orelse return null, 10) catch return null;
    return switch (id) {
        10 => .{ .id = 10, .owner = "1", .title = "mine" },
        11 => .{ .id = 11, .owner = "2", .title = "theirs" },
        else => null,
    };
}
fn loadPostPlain(c: *Ctx) ?Post {
    _ = c;
    return .{ .id = 1, .owner = "1", .title = "plain" };
}
fn loadPostOrError(c: *Ctx) !Post {
    _ = c;
    return error.DatabaseDown;
}
fn ownsLoaded(c: *Ctx, post: *const Post) bool {
    return std.mem.eql(u8, post.owner, c.userId() orelse "");
}

fn postCtx(a: std.mem.Allocator, user: ?[]const u8, id: []const u8) !Ctx {
    var c = bareCtx(a);
    if (user) |u| try c.setUser(.{ .id = u });
    try c.params.put(a, "id", id);
    return c;
}

test "resourcePolicy: loads the resource once and hands it to the request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const mw = rbac.requirePolicy(rbac.resourcePolicy("post_owner", Post, .{ .load = loadPost, .check = ownsLoaded }));
    var c = try postCtx(arena.allocator(), "1", "10");
    load_calls = 0;
    try std.testing.expectEqual(@as(?anyerror, null), failure(mw, &c));
    try std.testing.expectEqual(@as(usize, 1), load_calls);
    try std.testing.expectEqualStrings("mine", c.loaded(Post).?.title);
    try std.testing.expect(c.loaded(Other) == null);
}

test "resourcePolicy: 404 when missing, 403 for someone else's, 404 with .deny = .not_found" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const owner = rbac.requirePolicy(rbac.resourcePolicy("post_owner", Post, .{ .load = loadPost, .check = ownsLoaded }));
    const hidden = rbac.requirePolicy(rbac.resourcePolicy("post_owner", Post, .{ .load = loadPost, .check = ownsLoaded, .deny = .not_found }));

    var missing = try postCtx(a, "1", "99");
    try std.testing.expectEqual(@as(?anyerror, error.NotFound), failure(owner, &missing));
    var theirs = try postCtx(a, "1", "11");
    try std.testing.expectEqual(@as(?anyerror, error.Forbidden), failure(owner, &theirs));
    try std.testing.expect(theirs.loaded(Post) == null); // denied: nothing handed on
    var theirs_hidden = try postCtx(a, "1", "11");
    try std.testing.expectEqual(@as(?anyerror, error.NotFound), failure(hidden, &theirs_hidden));
}

test "resourcePolicy: anonymous gets 401 before any lookup, unless the route is public" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mw = rbac.requirePolicy(rbac.resourcePolicy("post_owner", Post, .{ .load = loadPost, .check = ownsLoaded }));
    var anon = try postCtx(a, null, "10");
    load_calls = 0;
    try std.testing.expectEqual(@as(?anyerror, error.Unauthorized), failure(mw, &anon));
    try std.testing.expectEqual(@as(usize, 0), load_calls);
    // Same answer for a post that doesn't exist: anonymous callers can't probe ids.
    var anon_missing = try postCtx(a, null, "99");
    try std.testing.expectEqual(@as(?anyerror, error.Unauthorized), failure(mw, &anon_missing));

    var public = try postCtx(a, null, "10");
    public._route.public = true;
    try std.testing.expectEqual(@as(?anyerror, error.Unauthorized), failure(mw, &public)); // check said no
    try std.testing.expectEqual(@as(usize, 1), load_calls);
}

test "resourcePolicy: loaders returning ?T, !?T or !T; loader errors propagate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try postCtx(a, "1", "1");
    try std.testing.expectEqual(@as(?anyerror, null), failure(rbac.requirePolicy(rbac.resourcePolicy("plain", Post, .{ .load = loadPostPlain, .check = ownsLoaded })), &c));
    try std.testing.expectEqualStrings("plain", c.loaded(Post).?.title);
    var d = try postCtx(a, "1", "1");
    try std.testing.expectEqual(@as(?anyerror, error.DatabaseDown), failure(rbac.requirePolicy(rbac.resourcePolicy("err", Post, .{ .load = loadPostOrError, .check = ownsLoaded })), &d));
}
