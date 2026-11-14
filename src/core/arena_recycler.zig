//! Internal: the request arenas of closed connections, kept warm for the
//! next connections. A connection takes one when it opens and gives it back
//! when it closes (reset to `Config.request_memory_retain`), so a new
//! connection does not start from an empty arena and ask the system for
//! its memory again. At most `cap` arenas are kept; the others are freed.
//! A short lock (taken twice per connection, not per request).

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;

/// Upper bound of `cap`.
pub const max_kept = 256;

pub const ArenaRecycler = struct {
    lock: std.atomic.Mutex = .unlocked,
    kept: [max_kept]ArenaAllocator = undefined,
    len: usize = 0,
    cap: usize,

    /// Keeps up to three quarters of `threads` arenas (at least one).
    pub fn init(threads: usize) ArenaRecycler {
        return .{ .cap = @min(max_kept, @max(1, threads * 3 / 4)) };
    }

    /// A kept arena, or a new one on `gpa`.
    pub fn take(self: *ArenaRecycler, gpa: std.mem.Allocator) ArenaAllocator {
        self.acquire();
        defer self.lock.unlock();
        if (self.len == 0) return .init(gpa);
        self.len -= 1;
        return self.kept[self.len];
    }

    /// Resets `arena` to keep at most `retain` bytes and keeps it, or frees
    /// it when `cap` arenas are kept already.
    pub fn give(self: *ArenaRecycler, arena: ArenaAllocator, retain: usize) void {
        var a = arena;
        _ = a.reset(.{ .retain_with_limit = retain });
        self.acquire();
        if (self.len < self.cap) {
            self.kept[self.len] = a;
            self.len += 1;
            self.lock.unlock();
            return;
        }
        self.lock.unlock();
        a.deinit();
    }

    /// Frees the kept arenas.
    pub fn deinit(self: *ArenaRecycler) void {
        for (self.kept[0..self.len]) |a| a.deinit();
        self.len = 0;
    }

    fn acquire(self: *ArenaRecycler) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }
};

const t = std.testing;

test "ArenaRecycler: a given arena comes back, warm; beyond cap it is freed" {
    var r = ArenaRecycler.init(4); // keeps 3
    defer r.deinit();
    var a = r.take(t.allocator);
    _ = try a.allocator().alloc(u8, 10_000);
    r.give(a, 1 << 20);
    try t.expectEqual(@as(usize, 1), r.len);

    var b = r.take(t.allocator);
    try t.expect(b.queryCapacity() >= 10_000); // the memory stayed
    try t.expectEqual(@as(usize, 0), r.len);
    r.give(b, 1 << 20);

    // Over the cap: freed (std.testing.allocator reports a leak otherwise).
    var many: [5]ArenaAllocator = undefined;
    for (&many) |*m| {
        m.* = r.take(t.allocator);
        _ = try m.allocator().alloc(u8, 100);
    }
    for (many) |m| r.give(m, 1 << 20);
    try t.expectEqual(@as(usize, 3), r.len);
}

test "ArenaRecycler: the retain limit applies when an arena is given back" {
    var r = ArenaRecycler.init(2);
    defer r.deinit();
    var a = r.take(t.allocator);
    _ = try a.allocator().alloc(u8, 200_000);
    r.give(a, 4096);
    var b = r.take(t.allocator);
    try t.expect(b.queryCapacity() <= 8192);
    r.give(b, 4096);
}
