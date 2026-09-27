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
            if (@hasField(C, "authenticated") and config.authenticated)
                out = out ++ &[_]MiddlewareFn{requireAuthenticated};
            if (@hasField(C, "roles") and config.roles.len > 0)
                out = out ++ &[_]MiddlewareFn{requireRoles(config.roles)};
            if (@hasField(C, "org_roles") and config.org_roles.len > 0)
                out = out ++ &[_]MiddlewareFn{requireOrgRoles(config.org_roles)};
            break :blk out;
        };
    };
    return S.list;
}

/// `.authenticated = true`: any logged-in user; 401 when the request carries
/// no identity (`_auth_sub` from jwks/keycloak/clerk, `_user_id` from the
/// HS256 `auth` middleware) — also when the app has no auth middleware.
pub fn requireAuthenticated(c: *Ctx, next: NextFn) anyerror!Response {
    if (c.params.get("_auth_sub") == null and c.params.get("_user_id") == null) return error.Unauthorized;
    return next(c);
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
