//! Internal: shutting a connection down from another thread (the watchdog's
//! deadlines, the hub closing a client) on every OS Spider builds for.

const std = @import("std");
const builtin = @import("builtin");

pub const How = enum(u8) { read, both };

/// shutdown() on `handle`; failures are ignored (the socket may be gone).
/// POSIX: the libc call, which needs no Io and is safe from any thread
/// under either backend. Windows: Zig's Io, whose sockets are AFD handles
/// that libc's shutdown does not know (Spider's only backend there is the
/// threaded one).
pub fn shutdown(io: std.Io, handle: std.Io.net.Socket.Handle, how: How) void {
    if (builtin.os.tag == .windows) {
        const s: std.Io.net.Stream = .{ .socket = .{ .handle = handle, .address = undefined } };
        s.shutdown(io, if (how == .read) .recv else .both) catch {};
    } else {
        _ = std.c.shutdown(handle, if (how == .read) std.c.SHUT.RD else std.c.SHUT.RDWR);
    }
}
