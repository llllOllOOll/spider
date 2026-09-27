//! The third argument of every route registration: `.{}` or any of
//!
//!   .roles     = &.{"admin"}        realm roles (any of)       -> 403 otherwise
//!   .org_roles = &.{"admin"}        roles in the active org    -> 403 otherwise
//!   .public    = true               no login required
//!   .authenticated = true           any logged-in user          -> 401 otherwise
//!   .quiet_log = true               successful requests not logged
//!   .allow_http = true              exempt from spider.forceHttps
//!
//! Checked at compile time: an unknown key (a typo like `.org_role` would
//! otherwise silently leave a route unprotected), or `.public` together with
//! roles or `.authenticated`, is a compile error.

const std = @import("std");
const RouteMeta = @import("router.zig").RouteMeta;
const MiddlewareFn = @import("../core/context.zig").MiddlewareFn;
const rbac = @import("../modules/rbac.zig");

const known = [_][]const u8{ "roles", "org_roles", "public", "authenticated", "quiet_log", "allow_http" };

pub fn validate(comptime config: anytype) void {
    const T = @TypeOf(config);
    if (@typeInfo(T) != .@"struct") @compileError("route config must be a struct literal like .{} or .{ .roles = ... }");
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        comptime var ok = false;
        inline for (known) |k| {
            if (comptime std.mem.eql(u8, name, k)) ok = true;
        }
        if (!ok) @compileError("unknown route option `." ++ name ++ "` (known: .roles, .org_roles, .public, .authenticated, .quiet_log, .allow_http)");
    }
    const meta = metaOf(config);
    if (meta.public and (meta.roles.len > 0 or meta.org_roles.len > 0))
        @compileError("a route can't be .public and require .roles/.org_roles at the same time");
    if (meta.public and meta.authenticated)
        @compileError("a route can't be .public and .authenticated at the same time");
}

/// Whether the config says anything about access (so it replaces a group's
/// default access rules instead of inheriting them).
pub fn declaresAccess(comptime config: anytype) bool {
    const T = @TypeOf(config);
    return @hasField(T, "roles") or @hasField(T, "org_roles") or @hasField(T, "public") or @hasField(T, "authenticated");
}

pub fn metaOf(comptime config: anytype) RouteMeta {
    const T = @TypeOf(config);
    var m: RouteMeta = .{};
    if (@hasField(T, "public")) m.public = config.public;
    if (@hasField(T, "authenticated")) m.authenticated = config.authenticated;
    if (@hasField(T, "quiet_log")) m.quiet_log = config.quiet_log;
    if (@hasField(T, "allow_http")) m.allow_http = config.allow_http;
    if (@hasField(T, "roles")) m.roles = config.roles;
    if (@hasField(T, "org_roles")) m.org_roles = config.org_roles;
    return m;
}

/// The RBAC middlewares for `config` (validated first).
pub fn middlewares(comptime config: anytype) []const MiddlewareFn {
    comptime validate(config);
    return rbac.routeMiddlewares(config);
}

test "metaOf / declaresAccess" {
    const m = comptime metaOf(.{ .org_roles = &[_][]const u8{"admin"}, .quiet_log = true });
    try std.testing.expect(m.quiet_log and !m.public and !m.allow_http);
    try std.testing.expectEqualStrings("admin", m.org_roles[0]);
    try std.testing.expect(comptime declaresAccess(.{ .public = true }));
    try std.testing.expect(comptime declaresAccess(.{ .roles = &[_][]const u8{"x"} }));
    try std.testing.expect(!comptime declaresAccess(.{ .quiet_log = true }));
    try std.testing.expect(!comptime declaresAccess(.{}));
    try std.testing.expect(comptime declaresAccess(.{ .authenticated = true }));
    try std.testing.expect((comptime metaOf(.{ .authenticated = true })).authenticated);
    comptime validate(.{ .authenticated = true, .roles = &[_][]const u8{"x"} });
    comptime validate(.{});
    comptime validate(.{ .public = true, .allow_http = true, .quiet_log = true });
}
