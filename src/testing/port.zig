//! Internal: the port of the server under test. spider.testing.start sets
//! it; the next listen() takes it (once) and listens there, on 127.0.0.1.
const std = @import("std");

var pending: std.atomic.Value(u32) = .init(0);

pub fn set(port: u16) void {
    pending.store(port, .release);
}

/// The port set for the next listen(), which it then forgets; null if none.
pub fn take() ?u16 {
    const port = pending.swap(0, .acq_rel);
    return if (port == 0) null else @intCast(port);
}

test "take gives the port once" {
    set(4123);
    try std.testing.expectEqual(@as(?u16, 4123), take());
    try std.testing.expectEqual(@as(?u16, null), take());
}
