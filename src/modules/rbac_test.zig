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
