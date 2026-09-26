const std = @import("std");
const spider = @import("../spider.zig");
const Ctx = spider.Ctx;
const Response = spider.Response;
const NextFn = spider.NextFn;
const MiddlewareFn = spider.MiddlewareFn;

/// Middlewares de RBAC para um config de rota (`.{ .roles = ..., .org_roles = ... }`),
/// resolvidos em comptime. Quando os dois campos estão presentes, os DOIS
/// precisam passar (cada um vira um middleware na cadeia).
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

/// Retorna um middleware que verifica se o usuário tem pelo menos uma das roles.
/// Deve ser executado DEPOIS do middleware de autenticação (jwks/keycloak).
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

/// Retorna um middleware que verifica se o usuário tem pelo menos uma das roles
/// dentro do claim organizations (Phase Two Keycloak).
pub fn requireOrgRoles(comptime roles: []const []const u8) MiddlewareFn {
    const S = struct {
        fn mw(c: *Ctx, next: NextFn) anyerror!Response {
            const count_str = c.params.get("_auth_orgs_count") orelse return error.Forbidden;
            const count = std.fmt.parseInt(usize, count_str, 10) catch return error.Forbidden;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const key = std.fmt.allocPrint(c.arena, "_auth_org_{d}_role", .{i}) catch continue;
                const role = c.params.get(key) orelse continue;
                for (roles) |required| {
                    if (std.mem.eql(u8, role, required)) return next(c);
                }
            }
            return error.Forbidden;
        }
    };
    return S.mw;
}
