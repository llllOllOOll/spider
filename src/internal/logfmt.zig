//! Log line helpers: UTC timestamps without an Io, TTY-aware color, and a
//! std.log function apps can plug in via std_options.

const std = @import("std");

/// Wall clock in nanoseconds since the Unix epoch (libc clock_gettime —
/// usable from std.log, which has no Io at hand).
pub fn nowNs() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// "2026-09-26T17:36:33.178Z"
pub fn utc(buf: *[24]u8, ns: i128) []const u8 {
    const total_ms: i128 = @divFloor(ns, std.time.ns_per_ms);
    const secs: u64 = @intCast(@max(0, @divFloor(total_ms, 1000)));
    const ms: u64 = @intCast(@mod(total_ms, 1000));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        yd.year,                 md.month.numeric(),        md.day_index + 1,
        ds.getHoursIntoDay(),    ds.getMinutesIntoHour(),   ds.getSecondsIntoMinute(),
        ms,
    }) catch "????-??-??T??:??:??.???Z";
}

var color_state = std.atomic.Value(u8).init(0); // 0 unknown, 1 on, 2 off

/// ANSI colors only when stderr is a terminal; a container log (docker,
/// kamal) gets plain text instead of "\x1b[32m" noise.
pub fn colorEnabled() bool {
    switch (color_state.load(.monotonic)) {
        1 => return true,
        2 => return false,
        else => {
            const on = std.c.isatty(2) == 1;
            color_state.store(if (on) 1 else 2, .monotonic);
            return on;
        },
    }
}

/// Drop-in std.log function that prefixes every line with a UTC timestamp:
///
/// ```zig
/// pub const std_options: std.Options = .{ .logFn = spider.logFn };
/// ```
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buf: [24]u8 = undefined;
    const ts = utc(&buf, nowNs());
    const scope_txt = if (scope == .default) "" else " (" ++ @tagName(scope) ++ ")";
    std.debug.print("{s} " ++ comptime level.asText() ++ scope_txt ++ ": " ++ format ++ "\n", .{ts} ++ args);
}

test "utc formats epoch and a known instant" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z", utc(&buf, 0));
    // 2026-09-26T17:36:33.178Z
    try std.testing.expectEqualStrings("2026-09-26T17:36:33.178Z", utc(&buf, 1790444193178 * std.time.ns_per_ms));
}
