//! The app's settings: `Config` is the type of the `config` constant that
//! an app declares in its `spider.config.zig`. Every field has a default, so
//! an app sets only what it changes.
const std = @import("std");

/// The value of `Config.env`.
pub const Env = enum {
    development,
    production,
    testing,
};

/// The settings of an app. `spider.app()` reads them from the `config`
/// constant of the project's `spider.config.zig` (the defaults below when
/// the project has no such file); `spider.appWithConfig(.{...})` takes them
/// in code.
///
/// ```zig
/// // spider.config.zig
/// const spider = @import("spider");
///
/// pub const config = spider.Config{
///     .views_dir = "./src",
///     .layout = "layout",
///     .env = .development,
///     .port = 3000,
///     .host = "0.0.0.0",
/// };
/// ```
pub const Config = struct {
    /// Port `listen()` binds when nothing else names one. `spider dev
    /// --port`, the `.port` given to `listen()` and the `PORT` variable
    /// (environment or `.env`) come first, in that order. Default 3000.
    port: u16 = 3000,
    /// Address `listen()` binds; the `.host` given to `listen()` replaces
    /// it. The default, "127.0.0.1", accepts local connections only: use
    /// "0.0.0.0" to accept connections from other machines (a container).
    host: []const u8 = "127.0.0.1",
    /// Directory of the templates that `c.view()` renders when they are
    /// read from disk: a view named "posts/index" is
    /// `<views_dir>/posts/index.html`. Default "./views" (a generated app
    /// sets "./src"). null: `c.view()` fails with error.ViewsNotConfigured.
    views_dir: ?[]const u8 = "./views",
    /// Not read by the server today: a template names its layout itself,
    /// with `extends "layout"`. Default "layout".
    layout: ?[]const u8 = "layout",
    /// Directory served as static files at "/" (before routing, always
    /// public). null: no static files. `server.staticDir()` / `staticAt()`
    /// override it.
    static_dir: ?[]const u8 = "./public",
    /// The environment the app declares. Nothing in Spider reads it today:
    /// it does not change any behaviour. Default `.development`.
    env: Env = .development,
    /// Accept threads of the threaded I/O backend (null: one per CPU).
    /// Ignored by the zio backend.
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
    /// Browser reload for `spider dev` (modules/dev_reload.zig): a script
    /// added to HTML pages plus `/_spider/dev.js` and `/_spider/dev`. null
    /// (the default): on when SPIDER_DEV is set, which `spider dev` does for
    /// the app it runs. Never on in a release build.
    dev_reload: ?bool = null,
    /// Every route must declare who may call it (`.public`, `.roles` or
    /// `.org_roles`, directly or through its group's defaults()); listen()
    /// refuses to start otherwise and names the routes that don't. Turns
    /// "forgot the RBAC" into a boot error. Also `server.requireRouteAccess()`.
    require_route_access: bool = false,
};

// internal: every field at its default; core/app.zig reads it.
pub const default = Config{};

// internal: the config of the project being built; `spider.app()` calls it.
pub fn fromRoot() Config {
    // spider_config is always available: either the project's spider.config.zig
    // (registered by myapp/build.zig) or the default fallback from spider's build.zig
    return @import("spider_config").config;
}
