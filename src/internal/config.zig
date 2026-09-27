const std = @import("std");

pub const Env = enum {
    development,
    production,
    testing,
};

pub const Config = struct {
    port: u16 = 3000,
    host: []const u8 = "127.0.0.1",
    views_dir: ?[]const u8 = "./views",
    layout: ?[]const u8 = "layout",
    static_dir: ?[]const u8 = "./public",
    env: Env = .development,
    workers: ?usize = null,
    /// Connection deadlines (ms, 0 = off), enforced by the connection
    /// watchdog so idle or stalled clients can't hold file descriptors
    /// forever. None applies while a handler runs, so SSE/WebSocket streams
    /// and slow handlers are unaffected.
    ///
    /// Waiting for the next request on a connection (the first one too).
    /// Keep it above the idle timeout of a reverse proxy in front (Go's
    /// default is 90 s), so the proxy, not the app, closes idle upstreams.
    keepalive_timeout_ms: u32 = 120_000,
    /// From the first byte of a request to its complete head (slowloris).
    header_timeout_ms: u32 = 30_000,
    /// Longest silence while receiving a request body; restarts on every
    /// chunk, so a slow but steady upload is never cut.
    body_timeout_ms: u32 = 60_000,
    /// Largest request body accepted, from its Content-Length: a bigger one
    /// is answered 413 before anything is read or allocated (the connection
    /// is then closed). Uploads that go straight to object storage (presigned
    /// URLs) never reach it; raise it for apps that take files through the app.
    max_body_bytes: u64 = 10 * 1024 * 1024,
    /// Cross-site request check, on by default: a state-changing request a
    /// browser sends from another site (CSRF) or a cross-site WebSocket
    /// upgrade gets 403 before routing. Non-browser clients (webhooks,
    /// servers) aren't affected. See core/origin.zig; add `trusted_origins`
    /// or `exempt_paths` for legitimate cross-site posts, `.enabled = false`
    /// to turn it off.
    origin_check: @import("../core/origin.zig").Policy = .{},
    /// Reverse proxies whose X-Forwarded-For is believed by `Ctx.clientIp()`:
    /// CIDRs or addresses, e.g. &.{"10.0.0.0/8", "172.16.0.0/12"} for a
    /// proxy on a private network. Empty (the default): the header is ignored.
    trusted_proxies: []const []const u8 = &.{},
    /// Longest a server push to an SSE/WebSocket client may stay blocked
    /// (its socket buffer full: the client stopped reading). The connection
    /// is then closed, so the client reconnects instead of silently missing
    /// events, and a stuck client can't hold up delivery to everyone else.
    stream_write_timeout_ms: u32 = 10_000,
    /// Every route must declare who may call it (`.public`, `.roles` or
    /// `.org_roles`, directly or through its group's defaults()); listen()
    /// refuses to start otherwise and names the routes that don't. Turns
    /// "forgot the RBAC" into a boot error. Also `server.requireRouteAccess()`.
    require_route_access: bool = false,
};

pub const default = Config{};

pub fn fromRoot() Config {
    // spider_config is always available: either the project's spider.config.zig
    // (registered by myapp/build.zig) or the default fallback from spider's build.zig
    return @import("spider_config").config;
}
