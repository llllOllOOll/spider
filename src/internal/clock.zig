//! Internal: the wall clock and a monotonic clock without an Io (std.log,
//! the watchdog thread and the health module have none at hand), on every
//! OS Spider builds for: clock_gettime where there is one, the same NT calls
//! std.Io uses on Windows.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

/// Nanoseconds since the Unix epoch. 0 when the clock cannot be read.
pub fn realtimeNs() i128 {
    if (builtin.os.tag == .windows) {
        // 100 ns ticks since 1601-01-01.
        const epoch_ns: i128 = std.time.epoch.windows * std.time.ns_per_s;
        return @as(i128, windows.ntdll.RtlGetSystemTimePrecise()) * 100 + epoch_ns;
    }
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Nanoseconds from an arbitrary start that never goes back. 0 when the
/// clock cannot be read.
pub fn monotonicNs() i64 {
    if (builtin.os.tag == .windows) {
        var qpf: windows.LARGE_INTEGER = undefined;
        var qpc: windows.LARGE_INTEGER = undefined;
        if (!windows.ntdll.RtlQueryPerformanceFrequency(&qpf).toBool()) return 0;
        if (!windows.ntdll.RtlQueryPerformanceCounter(&qpc).toBool()) return 0;
        const ns = @divTrunc(@as(i128, qpc) * std.time.ns_per_s, @as(i128, qpf));
        return @intCast(ns);
    }
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

test "the clocks move forward" {
    const a = monotonicNs();
    const b = monotonicNs();
    try std.testing.expect(a > 0 and b >= a);
    // After 2020-01-01, in nanoseconds.
    try std.testing.expect(realtimeNs() > 1_577_836_800 * std.time.ns_per_s);
}
