//! Connection deadlines for Server.listen().
//!
//! Without them a client that connects and sends nothing, sends a request
//! head one byte at a time, or stops halfway through a body holds its file
//! descriptor (and its task) forever; enough of them exhaust the fd limit.
//!
//! Each connection registers an Entry and arms it with a deadline before
//! every blocking read it wants bounded. A single watchdog thread sweeps
//! the registry and shuts down the READ side of connections past their
//! deadline: that wakes the blocked read on both io backends (a blocking
//! recv on Io.Threaded, the epoll wait on zio) with end-of-stream, and the
//! connection loop closes the socket through its normal path. The write
//! side stays open, so the server can still answer (e.g. 400 for a body
//! that stopped arriving). A write deadline (armWrite, used for pushes to
//! SSE/WebSocket clients) shuts down both sides instead: the blocked write
//! fails and the stream's handler wakes up and ends.
//!
//! fd reuse: an Entry is removed (under `lock`) before its socket is
//! closed, and the sweep shuts sockets down while holding `lock`, so it can
//! never hit a descriptor number that was already recycled.

const std = @import("std");

pub const Watchdog = struct {
    lock: std.atomic.Mutex = .unlocked,
    head: ?*Entry = null,

    pub const Entry = struct {
        fd: std.posix.fd_t,
        /// Monotonic ns after which the socket is shut down; 0 = no deadline.
        deadline: std.atomic.Value(i64) = .init(0),
        /// shutdown() `how` for the armed deadline (SHUT.RD or SHUT.RDWR).
        how: std.atomic.Value(i32) = .init(std.c.SHUT.RD),
        prev: ?*Entry = null,
        next: ?*Entry = null,

        /// Shut the connection down if it is still in this phase `ms` from
        /// now. 0 disarms.
        pub fn arm(e: *Entry, ms: u32) void {
            e.how.store(std.c.SHUT.RD, .release);
            e.deadline.store(if (ms == 0) 0 else monotonicNs() + @as(i64, ms) * std.time.ns_per_ms, .release);
        }

        /// Like arm(), for a write: on expiry both directions are shut down.
        pub fn armWrite(e: *Entry, ms: u32) void {
            e.how.store(std.c.SHUT.RDWR, .release);
            e.deadline.store(if (ms == 0) 0 else monotonicNs() + @as(i64, ms) * std.time.ns_per_ms, .release);
        }

        pub fn disarm(e: *Entry) void {
            e.deadline.store(0, .release);
        }
    };

    fn acquire(self: *Watchdog) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn add(self: *Watchdog, e: *Entry) void {
        self.acquire();
        defer self.lock.unlock();
        e.prev = null;
        e.next = self.head;
        if (self.head) |h| h.prev = e;
        self.head = e;
    }

    /// Must run before the entry's socket is closed.
    pub fn remove(self: *Watchdog, e: *Entry) void {
        self.acquire();
        defer self.lock.unlock();
        if (e.prev) |p| p.next = e.next else self.head = e.next;
        if (e.next) |n| n.prev = e.prev;
        e.prev = null;
        e.next = null;
    }

    /// Shuts down every connection past its deadline; returns how many.
    pub fn sweep(self: *Watchdog, now: i64) usize {
        self.acquire();
        defer self.lock.unlock();
        var n: usize = 0;
        var it = self.head;
        while (it) |e| : (it = e.next) {
            const d = e.deadline.load(.acquire);
            if (d == 0 or now < d) continue;
            e.deadline.store(0, .release);
            _ = std.c.shutdown(e.fd, e.how.load(.acquire));
            n += 1;
        }
        return n;
    }

    /// Watchdog thread body: sweeps every `tick_ms` for the life of the
    /// process (like the interval threads, it is never joined).
    pub fn run(self: *Watchdog, io: std.Io, tick_ms: u32) void {
        while (true) {
            std.Io.sleep(io, .fromMilliseconds(tick_ms), .real) catch {};
            _ = self.sweep(monotonicNs());
        }
    }
};

/// Sweep period for a set of timeouts: a quarter of the shortest enabled
/// one, clamped to [50 ms, 1 s], so a deadline fires at most ~25% late.
pub fn tickFor(timeouts_ms: []const u32) u32 {
    var min: u32 = std.math.maxInt(u32);
    for (timeouts_ms) |t| if (t != 0 and t < min) {
        min = t;
    };
    if (min == std.math.maxInt(u32)) return 1000;
    return std.math.clamp(min / 4, 50, 1000);
}

pub fn monotonicNs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

test "tickFor" {
    try std.testing.expectEqual(@as(u32, 1000), tickFor(&.{ 0, 0 }));
    try std.testing.expectEqual(@as(u32, 1000), tickFor(&.{ 60_000, 30_000 }));
    try std.testing.expectEqual(@as(u32, 75), tickFor(&.{ 300, 0, 120_000 }));
    try std.testing.expectEqual(@as(u32, 50), tickFor(&.{100}));
}

test "sweep shuts down only expired, armed entries" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds));
    var fds2: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds2));
    defer for (fds ++ fds2) |fd| {
        _ = std.c.close(fd);
    };

    var wd: Watchdog = .{};
    var expired: Watchdog.Entry = .{ .fd = fds[0] };
    var alive: Watchdog.Entry = .{ .fd = fds2[0] };
    wd.add(&expired);
    wd.add(&alive);
    defer wd.remove(&alive);

    expired.deadline.store(1, .release); // long past
    alive.arm(60_000);
    try std.testing.expectEqual(@as(usize, 1), wd.sweep(monotonicNs()));
    try std.testing.expectEqual(@as(i64, 0), expired.deadline.load(.acquire)); // fires once
    try std.testing.expectEqual(@as(usize, 0), wd.sweep(monotonicNs()));

    // The shut-down end now reads EOF; the other one is untouched.
    var b: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), std.c.read(fds[0], &b, 1));
    wd.remove(&expired);
    try std.testing.expect(wd.head == &alive);
}
