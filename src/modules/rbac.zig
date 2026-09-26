const std = @import("std");
const spider = @import("../spider.zig");
const Ctx = spider.Ctx;
const Response = spider.Response;
const NextFn = spider.NextFn;
const MiddlewareFn = spider.MiddlewareFn;

/// RBAC middlewares for a route config (`.{ .roles = ..., .org_roles = ... }`),
/// resolved at comptime. When both fields are present, BOTH must pass (each
/// becomes its own middleware in the chain).
pub fn routeMiddlewares(comptime config: anytype) []const MiddlewareFn {
    const C = @TypeOf(config);
    const S = struct {
        const list: []const MiddlewareFn = blk: {
            var out: []const MiddlewareFn = &.{};
            if (@hasField(C, "roles") and config.roles.len > 0)
                out = out ++ &[_]MiddlewareFn{requireRoles(config.roles)};
            if (@hasField(C, "org_roles") and config.org_roles.len > 0)
                out = out ++ &[_]MiddlewareFn{requireOrgRoles(config.org_roles)};
            break :blk out;
        };
    };
    return S.list;
}

/// Returns a middleware that requires the user to hold at least one of `roles`
/// (realm roles). Must run AFTER the auth middleware (jwks/keycloak).
pub fn requireRoles(comptime roles: []const []const u8) MiddlewareFn {
    const S = struct {
        fn mw(c: *Ctx, next: NextFn) anyerror!Response {
            for (roles) |required| {
                if (c.hasRole(required)) return next(c);
            }
            return error.Forbidden;
        }
    };
    return S.mw;
}

/// Returns a middleware that requires the user to hold at least one of `roles`
/// in the organizations claim (Phase Two Keycloak).
///
/// When an active org is set (`c.activeOrgId()`, from the provider's
/// `active_org_cookie` or an app middleware calling `c.setActiveOrg`), only
/// roles held in THAT org count — being admin of org A does not open a route
/// while org B is active. With no active org selected, a role held in any of
/// the user's orgs is accepted.
pub fn requireOrgRoles(comptime roles: []const []const u8) MiddlewareFn {
    const S = struct {
        fn mw(c: *Ctx, next: NextFn) anyerror!Response {
            if (c.orgRoleIn(roles, c.activeOrgId())) return next(c);
            return error.Forbidden;
        }
    };
    return S.mw;
}
