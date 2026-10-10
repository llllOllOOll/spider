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

/// Options of `spider.forceHttps`. Only `default_base_url` is required.
pub const Options = struct {
    /// Env var with the public origin ("https://example.com", no final
    /// slash), read for each request that is redirected.
    base_url_env: []const u8 = "BASE_URL",
    /// Used when the env var is unset.
    default_base_url: []const u8,
    /// Header carrying the original scheme. Without it (dev, no proxy) the
    /// request is taken as HTTPS and never redirected. When it lists
    /// several values (a chain of proxies: "https, http"), the first one
    /// counts: the one the client used.
    proto_header: []const u8 = "X-Forwarded-Proto",
    /// Request targets that are never redirected: an exact match (the query
    /// string counts), or a prefix when the entry ends in `*`. Unlike a
    /// route's `.allow_http`, it also covers paths no route matches.
    allow_http_paths: []const []const u8 = &.{},
};

/// A middleware that redirects a request that arrived over plain HTTP to the
/// same path and query on the HTTPS origin (302). The scheme is read from
/// `proto_header`: the app must be behind a proxy that sets it. A request
/// without that header is taken as HTTPS and passes. Routes with
/// `.allow_http = true` and the `allow_http_paths` are not redirected.
///
/// ```zig
/// server.use(spider.forceHttps(.{
///     .default_base_url = "https://example.test",
///     .allow_http_paths = &.{ "/legacy*", "/exact" },
/// }))
/// ```
pub fn forceHttps(comptime opts: Options) MiddlewareFn {
    return struct {
        fn mw(c: *Ctx, next: NextFn) anyerror!Response {
            const target = c.getPath();
            if (c.route().allow_http or pathAllowed(opts.allow_http_paths, target)) return next(c);
            const proto = c.header(opts.proto_header) orelse "https";
            if (isHttps(proto)) return next(c);
            const base = env.getOr(opts.base_url_env, opts.default_base_url);
            return c.redirect(try std.fmt.allocPrint(c.arena, "{s}{s}", .{ base, target }));
        }
    }.mw;
}

/// Whether the proxy's protocol header says the client came over HTTPS.
/// Behind more than one proxy the header lists a value per hop
/// ("https, http"): the first is the one the client used.
fn isHttps(proto: []const u8) bool {
    const first = if (std.mem.indexOfScalar(u8, proto, ',')) |comma| proto[0..comma] else proto;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, first, " \t"), "https");
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

test "isHttps: the protocol the client used, as proxies write it" {
    try std.testing.expect(isHttps("https"));
    try std.testing.expect(!isHttps("http"));
    // A chain of proxies lists one value per hop, the client's first.
    try std.testing.expect(isHttps("https, http"));
    try std.testing.expect(isHttps("https,http"));
    try std.testing.expect(!isHttps("http, https"));
    try std.testing.expect(isHttps("HTTPS"));
    try std.testing.expect(isHttps(" https "));
    try std.testing.expect(!isHttps(""));
    try std.testing.expect(!isHttps("httpsx"));
}
