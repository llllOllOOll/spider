//! spider.forceHttps(.{ ... }): redirect plain-HTTP requests to the HTTPS
//! origin, for apps behind a TLS-terminating proxy that forwards the
//! original scheme (X-Forwarded-Proto) but doesn't redirect by itself.
//!
//! Exempt: routes declaring `.allow_http = true`, and `allow_http_paths`
//! (compared with the request target: exact, or a prefix when the entry
//! ends in '*') — the latter also covers paths no route matches.

const std = @import("std");
const ctx_mod = @import("../core/context.zig");
const Ctx = ctx_mod.Ctx;
const Response = ctx_mod.Response;
const NextFn = ctx_mod.NextFn;
const MiddlewareFn = ctx_mod.MiddlewareFn;
const env = @import("../internal/env.zig");

pub const Options = struct {
    /// Env var with the public origin ("https://example.com"), read per request.
    base_url_env: []const u8 = "BASE_URL",
    /// Used when the env var is unset.
    default_base_url: []const u8,
    /// Header carrying the original scheme. Without it (dev, no proxy) the
    /// request is taken as HTTPS and never redirected.
    proto_header: []const u8 = "X-Forwarded-Proto",
    allow_http_paths: []const []const u8 = &.{},
};

pub fn forceHttps(comptime opts: Options) MiddlewareFn {
    return struct {
        fn mw(c: *Ctx, next: NextFn) anyerror!Response {
            const target = c.getPath();
            if (c.route().allow_http or pathAllowed(opts.allow_http_paths, target)) return next(c);
            const proto = c.header(opts.proto_header) orelse "https";
            if (std.mem.eql(u8, proto, "https")) return next(c);
            const base = env.getOr(opts.base_url_env, opts.default_base_url);
            return c.redirect(try std.fmt.allocPrint(c.arena, "{s}{s}", .{ base, target }));
        }
    }.mw;
}

fn pathAllowed(paths: []const []const u8, target: []const u8) bool {
    for (paths) |p| {
        if (p.len > 0 and p[p.len - 1] == '*') {
            if (std.mem.startsWith(u8, target, p[0 .. p.len - 1])) return true;
        } else if (std.mem.eql(u8, target, p)) return true;
    }
    return false;
}

test "pathAllowed: exact, or prefix with a trailing *" {
    const paths = [_][]const u8{ "/keepalive", "/api/access/intelbras*" };
    try std.testing.expect(pathAllowed(&paths, "/keepalive"));
    try std.testing.expect(!pathAllowed(&paths, "/keepalive?x=1")); // exact means exact
    try std.testing.expect(pathAllowed(&paths, "/api/access/intelbras/auth"));
    try std.testing.expect(pathAllowed(&paths, "/api/access/intelbras"));
    try std.testing.expect(!pathAllowed(&paths, "/api/access/other"));
}
