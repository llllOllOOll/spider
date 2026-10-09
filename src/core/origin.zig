//! Internal: cross-site request check (CSRF, and cross-site WebSocket
//! hijacking), on by default: a state-changing request a browser sends from
//! another site is answered 403 before routing.
//!
//!   - safe methods (GET/HEAD/OPTIONS) pass, except a WebSocket upgrade;
//!   - `Sec-Fetch-Site: same-origin | none` passes; `same-site` (a sibling
//!     subdomain, which SameSite=Lax cookies still reach) and `cross-site`
//!     pass only for a trusted origin;
//!   - without Sec-Fetch-Site (older browsers), `Origin` must match `Host`
//!     or be trusted;
//!   - with neither header the client is not a browser (webhooks, servers,
//!     curl): it passes — CSRF needs a browser carrying the user's cookies.
//!
//! Configured with `Config.origin_check`; `exempt_paths` for endpoints a
//! browser legitimately posts to from another site (e.g. an IdP or payment
//! provider's form_post callback).

const std = @import("std");

pub const Policy = struct {
    enabled: bool = true,
    /// Full origins allowed besides the app's own, e.g. "https://auth.example.com".
    trusted_origins: []const []const u8 = &.{},
    /// Paths not checked: an exact path, a path followed by "/...", or any
    /// path under an entry that ends with "/".
    exempt_paths: []const []const u8 = &.{},
};

pub const Request = struct {
    method: std.http.Method,
    path: []const u8,
    host: ?[]const u8,
    origin: ?[]const u8,
    sec_fetch_site: ?[]const u8,
    upgrade: ?[]const u8,
};

pub fn allowed(policy: Policy, r: Request) bool {
    if (!policy.enabled) return true;
    const is_ws = if (r.upgrade) |u| std.ascii.eqlIgnoreCase(u, "websocket") else false;
    const safe = r.method == .GET or r.method == .HEAD or r.method == .OPTIONS;
    if (safe and !is_ws) return true;
    if (exempt(policy, r.path)) return true;

    if (r.sec_fetch_site) |site| {
        if (std.ascii.eqlIgnoreCase(site, "same-origin") or std.ascii.eqlIgnoreCase(site, "none")) return true;
        return if (r.origin) |o| trusted(policy, o) else false;
    }
    const o = r.origin orelse return true; // not a browser
    if (trusted(policy, o)) return true;
    const host = r.host orelse return false;
    return std.ascii.eqlIgnoreCase(originHost(o) orelse return false, host);
}

/// "https://app.example.com:8443" -> "app.example.com:8443"; null for
/// anything that isn't scheme://host ("null", a bare string).
fn originHost(o: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, o, "://") orelse return null;
    const rest = o[sep + 3 ..];
    if (rest.len == 0 or std.mem.indexOfAny(u8, rest, "/?#") != null) return null;
    return rest;
}

fn trusted(policy: Policy, o: []const u8) bool {
    for (policy.trusted_origins) |t| {
        if (std.ascii.eqlIgnoreCase(t, o)) return true;
    }
    return false;
}

fn exempt(policy: Policy, path: []const u8) bool {
    for (policy.exempt_paths) |e| {
        if (std.mem.eql(u8, path, e)) return true;
        if (e.len > 0 and std.mem.startsWith(u8, path, e) and (e[e.len - 1] == '/' or path[e.len] == '/')) return true;
    }
    return false;
}
