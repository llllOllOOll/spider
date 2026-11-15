//! Internal: the few system calls Spider makes outside std.Io, for code that
//! has no Io at hand (std.log, the connection watchdog, the health
//! handlers). POSIX systems go through libc; Windows through ntdll,
//! kernel32 and ws2_32.

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;
const windows = std.os.windows;

/// Nanoseconds on a clock that only moves forward (not the wall clock);
/// 0 when it cannot be read.
pub fn monotonicNs() i64 {
    if (is_windows) {
        var count: windows.LARGE_INTEGER = undefined;
        var freq: windows.LARGE_INTEGER = undefined;
        if (windows.ntdll.RtlQueryPerformanceCounter(&count) == .FALSE) return 0;
        if (windows.ntdll.RtlQueryPerformanceFrequency(&freq) == .FALSE or freq <= 0) return 0;
        const secs = @divTrunc(count, freq);
        const rest = @rem(count, freq);
        return secs * std.time.ns_per_s + @divTrunc(rest * std.time.ns_per_s, freq);
    }
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Wall clock in nanoseconds since the Unix epoch; 0 when it cannot be read.
pub fn realtimeNs() i128 {
    if (is_windows) {
        // 100 ns intervals since 1601-01-01.
        const since_1601: i128 = windows.ntdll.RtlGetSystemTimePrecise();
        const epoch_diff: i128 = 116_444_736_000_000_000;
        return (since_1601 - epoch_diff) * 100;
    }
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// A socket, as `std.Io.net.Stream.socket.handle` holds it.
pub const Socket = std.Io.net.Socket.Handle;

/// Which side of a socket `shutdown` closes.
pub const Shut = enum(u8) { read, both };

/// Shuts down one or both sides of `s`, waking a read (and, for `.both`, a
/// write) blocked on it. Errors are ignored: the socket may be closing.
pub fn shutdown(s: Socket, how: Shut) void {
    if (is_windows) {
        const sd: i32 = switch (how) {
            .read => 0, // SD_RECEIVE
            .both => 2, // SD_BOTH
        };
        _ = win.shutdown(s, sd);
        return;
    }
    _ = std.c.shutdown(s, switch (how) {
        .read => std.c.SHUT.RD,
        .both => std.c.SHUT.RDWR,
    });
}

/// Whether stderr is a terminal that shows ANSI colors. On Windows, a
/// console with virtual terminal processing on.
pub fn stderrShowsColor() bool {
    if (is_windows) {
        const h = windows.peb().ProcessParameters.hStdError;
        var mode: u32 = 0;
        if (win.GetConsoleMode(h, &mode) == .FALSE) return false;
        const ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;
        return mode & ENABLE_VIRTUAL_TERMINAL_PROCESSING != 0;
    }
    return std.c.isatty(std.c.STDERR_FILENO) == 1;
}

/// Declared here: std.os.windows has neither. Only referenced on Windows.
const win = struct {
    extern "ws2_32" fn shutdown(s: windows.HANDLE, how: i32) callconv(.winapi) i32;
    extern "kernel32" fn GetConsoleMode(console: windows.HANDLE, mode: *u32) callconv(.winapi) windows.BOOL;
};

test "the monotonic clock moves forward" {
    const a = monotonicNs();
    const b = monotonicNs();
    try std.testing.expect(a > 0);
    try std.testing.expect(b >= a);
}

test "the wall clock is after 2025" {
    const jan_2025_ns: i128 = 1_735_689_600 * std.time.ns_per_s;
    try std.testing.expect(realtimeNs() > jan_2025_ns);
}
