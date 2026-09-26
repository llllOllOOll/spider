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
    /// Longest a server push to an SSE/WebSocket client may stay blocked
    /// (its socket buffer full: the client stopped reading). The connection
    /// is then closed, so the client reconnects instead of silently missing
    /// events, and a stuck client can't hold up delivery to everyone else.
    stream_write_timeout_ms: u32 = 10_000,
};

pub const default = Config{};

pub fn fromRoot() Config {
    // spider_config is always available: either the project's spider.config.zig
    // (registered by myapp/build.zig) or the default fallback from spider's build.zig
    return @import("spider_config").config;
}
