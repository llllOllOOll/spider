const std = @import("std");
const spider = @import("../spider.zig");
const Ctx = spider.Ctx;
const Response = spider.Response;
const NextFn = spider.NextFn;
const MiddlewareFn = spider.MiddlewareFn;

/// RBAC middlewares for a route config (`.{ .roles = ..., .org_roles = ...,
/// .policy = ... }`), resolved at comptime. Every field present must pass
/// (each becomes its own middleware in the chain, the policy last).
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
            if (@hasField(C, "policy"))
                out = out ++ &[_]MiddlewareFn{requirePolicy(config.policy)};
            break :blk out;
        };
    };
    return S.list;
}

/// `.authenticated = true`: any logged-in user; 401 when the request carries
/// no identity (`_auth_sub` from jwks/keycloak/clerk, `_user_id` from the
/// HS256 `auth` middleware) — also when the app has no auth middleware.
pub fn requireAuthenticated(c: *Ctx, next: NextFn) anyerror!Response {
    if (c.userId() == null) return error.Unauthorized;
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

/// A named access rule for rules that aren't a role: "owns the post", "the
/// org is on a paid plan", "the webhook signature is valid". Declared on a
/// route as `.policy = spider.policy("post_owner", isPostOwner)`; the name
/// is what the route listing, routes.lock and expectRoutes show.
pub const Policy = struct {
    name: []const u8,
    check: *const fn (*Ctx) anyerror!bool,
};

/// `check` is `fn (*Ctx) bool` or `fn (*Ctx) !bool`, and runs after the
/// route's `.authenticated` / `.roles` / `.org_roles` checks. When it says
/// no, the request fails with 403, or 401 when there is no logged-in user
/// (like ASP.NET's Forbid / Challenge); an error it returns is the
/// request's error. `name`: letters, digits and `_ . : -`.
pub fn policy(comptime name: []const u8, comptime check: anytype) Policy {
    comptime {
        if (name.len == 0) @compileError("spider.policy: the name can't be empty");
        for (name) |ch| {
            if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == ':' or ch == '-'))
                @compileError("spider.policy(\"" ++ name ++ "\"): use letters, digits and _ . : - in the name");
        }
        const info = @typeInfo(@TypeOf(check));
        if (info != .@"fn" or info.@"fn".param_types.len != 1 or info.@"fn".param_types[0] != *Ctx)
            @compileError("spider.policy(\"" ++ name ++ "\"): the check must be fn (*spider.Ctx) bool or fn (*spider.Ctx) !bool");
    }
    const S = struct {
        fn f(c: *Ctx) anyerror!bool {
            return check(c);
        }
    };
    return .{ .name = name, .check = S.f };
}

/// The middleware behind a route's `.policy`.
pub fn requirePolicy(comptime p: Policy) MiddlewareFn {
    const S = struct {
        fn mw(c: *Ctx, next: NextFn) anyerror!Response {
            if (try p.check(c)) return next(c);
            return if (c.userId() == null) error.Unauthorized else error.Forbidden;
        }
    };
    return S.mw;
}

/// What a resourcePolicy answers when its check says no.
pub const Deny = enum {
    /// 403: the caller learns the resource exists.
    forbidden,
    /// 404, like a missing one: ids can't be probed (GitHub's approach
    /// for private repositories).
    not_found,
};

/// A policy about the one resource a route works on (a post, a ticket):
///
///     .policy = spider.resourcePolicy("post_owner", Post, .{
///         .load = loadPost,   // fn (*Ctx) ?Post, !?Post or !Post — from c.params etc.
///         .check = isOwner,   // fn (*Ctx, *const Post) bool or !bool
///         .deny = .forbidden, // or .not_found (optional)
///     })
///
/// In order: an anonymous request on a non-public route is refused (401)
/// before anything is loaded; a missing resource is error.NotFound (404);
/// then `check` decides (403, or 404 with .deny = .not_found). An allowed
/// resource reaches the handler, loaded once, as `spider.Loaded(Post)` or
/// `c.loaded(Post)`. SSE handlers (`*Sse`) don't see it.
pub fn resourcePolicy(comptime name: []const u8, comptime T: type, comptime opts: anytype) Policy {
    const O = @TypeOf(opts);
    comptime {
        for (@typeInfo(O).@"struct".field_names) |f| {
            if (!std.mem.eql(u8, f, "load") and !std.mem.eql(u8, f, "check") and !std.mem.eql(u8, f, "deny"))
                @compileError("spider.resourcePolicy(\"" ++ name ++ "\"): unknown option `." ++ f ++ "` (known: .load, .check, .deny)");
        }
        if (!@hasField(O, "load") or !@hasField(O, "check"))
            @compileError("spider.resourcePolicy(\"" ++ name ++ "\"): needs .load and .check");
        const load_info = @typeInfo(@TypeOf(opts.load));
        if (load_info != .@"fn" or load_info.@"fn".param_types.len != 1 or load_info.@"fn".param_types[0] != *Ctx)
            @compileError("spider.resourcePolicy(\"" ++ name ++ "\"): .load must be fn (*spider.Ctx) ?" ++ @typeName(T) ++ " (or !?T, !T)");
        const R = load_info.@"fn".return_type.?;
        const Payload = if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.payload else R;
        if (Payload != T and Payload != ?T)
            @compileError("spider.resourcePolicy(\"" ++ name ++ "\"): .load returns " ++ @typeName(R) ++ ", expected ?" ++ @typeName(T) ++ ", !?" ++ @typeName(T) ++ " or !" ++ @typeName(T));
        const check_info = @typeInfo(@TypeOf(opts.check));
        if (check_info != .@"fn" or check_info.@"fn".param_types.len != 2 or check_info.@"fn".param_types[0] != *Ctx or check_info.@"fn".param_types[1] != *const T)
            @compileError("spider.resourcePolicy(\"" ++ name ++ "\"): .check must be fn (*spider.Ctx, *const " ++ @typeName(T) ++ ") bool or !bool");
    }
    const deny: Deny = if (@hasField(O, "deny")) opts.deny else .forbidden;
    const S = struct {
        fn load(c: *Ctx) anyerror!?T {
            const r = opts.load(c);
            if (@typeInfo(@TypeOf(r)) == .error_union) {
                const v = try r;
                return v;
            }
            return r;
        }
        fn check(c: *Ctx) anyerror!bool {
            if (c.userId() == null and !c.route().public) return false;
            const value = (try load(c)) orelse return error.NotFound;
            const res = try c.arena.create(T);
            res.* = value;
            const allowed: anyerror!bool = opts.check(c, res);
            if (!try allowed) {
                if (deny == .not_found) return error.NotFound;
                return false;
            }
            c.setLoaded(T, res);
            return true;
        }
    };
    // The name rules and the (*Ctx) bool shape are policy()'s.
    return policy(name, S.check);
}
