const std = @import("std");
const Ctx = @import("../core/context.zig").Ctx;
const NextFn = @import("../core/context.zig").NextFn;
const MiddlewareFn = @import("../core/context.zig").MiddlewareFn;
const Response = @import("../core/context.zig").Response;
const logfmt = @import("../internal/logfmt.zig");

const reset = "\x1b[0m";
const green = "\x1b[32m";
const blue = "\x1b[34m";
const yellow = "\x1b[33m";
const red = "\x1b[31m";

pub const Options = struct {
    /// Paths whose successful (< 400) requests are not logged — heartbeats,
    /// polling, health checks. Segment globs: "*" matches one segment,
    /// a trailing "**" matches the rest ("/tickets/*/presence",
    /// "/api/access/intelbras/**"). Errors and 4xx/5xx are always logged.
    quiet_paths: []const []const u8 = &.{},
    /// Also log SSE/WebSocket connection opens ("open" lines).
    log_stream_open: bool = true,
};

/// Request log line:
///   2026-09-26T17:36:33.178Z [200] GET /tickets/42 3.1ms rid=… user=… org=…
/// `user` is the auth subject (an id, never email/name) and `org` the active
/// org, both filled in by the auth middleware later in the chain ("-" when
/// absent). The query string is left out: it can carry tokens.
pub fn middleware(c: *Ctx, next: NextFn) anyerror!Response {
    return run(.{}, c, next);
}

/// `spider.loggerWith(.{ .quiet_paths = &.{"/keepalive"} })`
pub fn with(comptime opts: Options) MiddlewareFn {
    return struct {
        fn mw(c: *Ctx, next: NextFn) anyerror!Response {
            return run(opts, c, next);
        }
    }.mw;
}

fn statusColor(status: u16) []const u8 {
    if (!logfmt.colorEnabled()) return "";
    if (status >= 100 and status < 200) return blue;
    if (status >= 200 and status < 300) return green;
    if (status >= 300 and status < 400) return blue;
    if (status >= 400 and status < 500) return yellow;
    if (status >= 500) return red;
    return reset;
}

fn resetColor() []const u8 {
    return if (logfmt.colorEnabled()) reset else "";
}

fn formatMs(ns: u64, buf: []u8) []const u8 {
    const ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
    return std.fmt.bufPrint(buf, "{d:.1}ms", .{ms}) catch "?ms";
}

/// Glob over "/"-separated segments: "*" = exactly one segment, a final
/// "**" = any remaining segments (including none).
pub fn pathMatches(pattern: []const u8, path: []const u8) bool {
    var pit = std.mem.splitScalar(u8, std.mem.trim(u8, pattern, "/"), '/');
    var sit = std.mem.splitScalar(u8, std.mem.trim(u8, path, "/"), '/');
    while (pit.next()) |p| {
        if (std.mem.eql(u8, p, "**")) return true;
        const seg = sit.next() orelse return false;
        if (std.mem.eql(u8, p, "*")) continue;
        if (!std.mem.eql(u8, p, seg)) return false;
    }
    return sit.next() == null;
}

fn isQuiet(comptime opts: Options, path: []const u8) bool {
    inline for (opts.quiet_paths) |p| {
        if (pathMatches(p, path)) return true;
    }
    return false;
}

fn run(comptime opts: Options, c: *Ctx, next: NextFn) anyerror!Response {
    const method = @tagName(c.request.head.method);
    const target = c.getPath();
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;

    const start = std.Io.Clock.now(.real, c._io);
    const resp = next(c) catch |err| {
        const lat_ns = elapsed(start, c);
        var lat_buf: [32]u8 = undefined;
        var ts_buf: [24]u8 = undefined;
        // The final status is decided by onError (or the default mapping)
        // after the chain returns, so report the error itself.
        std.debug.print("{s} {s}[ERR]{s} {s: <6} {s}  {s}  rid={s} user={s} org={s}  error={s}{s}{s}\n", .{
            logfmt.utc(&ts_buf, logfmt.nowNs()), statusColor(500), resetColor(), method, path,
            formatMs(lat_ns, &lat_buf),          c.requestId(),     userOf(c),    orgOf(c),
            @errorName(err),                     if (c.errorDetail() != null) " detail=" else "",
            c.errorDetail() orelse "",
        });
        return err;
    };

    const status_int: u16 = @intFromEnum(resp.status);
    if (status_int < 400 and isQuiet(opts, path)) return resp;
    if (resp.raw and !opts.log_stream_open) return resp;

    var ts_buf: [24]u8 = undefined;
    const ts = logfmt.utc(&ts_buf, logfmt.nowNs());
    const sc = statusColor(status_int);
    if (resp.raw) {
        std.debug.print("{s} {s}[{d}]{s} {s: <6} {s}  open  rid={s} user={s} org={s}\n", .{ ts, sc, status_int, resetColor(), method, path, c.requestId(), userOf(c), orgOf(c) });
    } else {
        var lat_buf: [32]u8 = undefined;
        std.debug.print("{s} {s}[{d}]{s} {s: <6} {s}  {s}  rid={s} user={s} org={s}\n", .{ ts, sc, status_int, resetColor(), method, path, formatMs(elapsed(start, c), &lat_buf), c.requestId(), userOf(c), orgOf(c) });
    }
    return resp;
}

fn elapsed(start: std.Io.Timestamp, c: *Ctx) u64 {
    const end = std.Io.Clock.now(.real, c._io);
    const d = end.nanoseconds - start.nanoseconds;
    return if (d < 0) 0 else @intCast(d);
}

fn userOf(c: *Ctx) []const u8 {
    return c.params.get("_auth_sub") orelse "-";
}

fn orgOf(c: *Ctx) []const u8 {
    return c.activeOrgId() orelse "-";
}

test "pathMatches" {
    const t = std.testing;
    try t.expect(pathMatches("/keepalive", "/keepalive"));
    try t.expect(!pathMatches("/keepalive", "/keepalive/x"));
    try t.expect(pathMatches("/tickets/*/presence", "/tickets/42/presence"));
    try t.expect(!pathMatches("/tickets/*/presence", "/tickets/42/messages"));
    try t.expect(!pathMatches("/tickets/*/presence", "/tickets/presence"));
    try t.expect(pathMatches("/api/access/intelbras/**", "/api/access/intelbras/auth"));
    try t.expect(pathMatches("/api/access/intelbras/**", "/api/access/intelbras"));
    try t.expect(!pathMatches("/api/access/intelbras/**", "/api/access/other"));
    try t.expect(pathMatches("/", "/"));
}
