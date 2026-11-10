//! `spider.health`: the two health-check handlers every `spider.app` has, at
//! `/up` and `/_spider/health`.

const std = @import("std");
const ctx_mod = @import("../core/context.zig");
const Ctx = ctx_mod.Ctx;
const Response = ctx_mod.Response;

var boot_time: i64 = 0;

/// Records the time `health` counts the uptime from. `spider.app` and
/// `spider.appWithConfig` call it.
pub fn init() void {
    boot_time = uptimeClock();
}

/// Answers 200 with the text `OK`. Registered at `/up`, public and left out
/// of the request log: what a load balancer or a deploy script polls.
pub fn up(c: *Ctx) !Response {
    return c.text("OK", .{});
}

/// Answers 200 with `{"status":"ok","uptime_seconds":N}`, N being the seconds
/// since `init`. Registered at `/_spider/health`, public and left out of the
/// request log. It checks nothing else (not the database).
pub fn health(c: *Ctx) !Response {
    const uptime = uptimeClock() - boot_time;

    return c.json(.{
        .status = "ok",
        .uptime_seconds = uptime,
    }, .{});
}

/// Seconds on the monotonic clock (the same on every OS).
fn uptimeClock() i64 {
    return @divTrunc(@import("../internal/clock.zig").monotonicNs(), std.time.ns_per_s);
}
