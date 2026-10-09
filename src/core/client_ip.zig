//! Internal: the client's address behind reverse proxies
//! (`Ctx.clientIp()`).
//!
//! `X-Forwarded-For` is written by whoever sends the request, so it is only
//! believed when the TCP peer is one of `Config.trusted_proxies`: then the
//! header is walked right to left, skipping trusted hops, and the first
//! untrusted address is the client. With no trusted proxies (the default)
//! the header is ignored and the peer address is the answer.

const std = @import("std");

/// `peer`: the TCP peer's address; `xff`: the X-Forwarded-For header;
/// `trusted`: CIDRs ("10.0.0.0/8", "fd00::/8") or single addresses.
pub fn resolve(peer: ?[]const u8, xff: ?[]const u8, trusted: []const []const u8) ?[]const u8 {
    const p = peer orelse return null;
    if (!isTrusted(p, trusted)) return p;
    const header = xff orelse return p;
    var leftmost: ?[]const u8 = null;
    var i: usize = header.len;
    while (true) {
        const start = if (std.mem.lastIndexOfScalar(u8, header[0..i], ',')) |c| c + 1 else 0;
        const hop = std.mem.trim(u8, header[start..i], " \t");
        if (hop.len > 0) {
            if (parse(hop) == null) return p; // garbage: don't guess
            if (!isTrusted(hop, trusted)) return hop;
            leftmost = hop;
        }
        if (start == 0) break;
        i = start - 1;
    }
    return leftmost orelse p;
}

const Addr = struct { bytes: [16]u8, len: u8 };

fn parse(s: []const u8) ?Addr {
    const a = std.Io.net.IpAddress.parse(s, 0) catch return null;
    return switch (a) {
        .ip4 => |v| blk: {
            var out: Addr = .{ .bytes = @splat(0), .len = 4 };
            @memcpy(out.bytes[0..4], &v.bytes);
            break :blk out;
        },
        .ip6 => |v| .{ .bytes = v.bytes, .len = 16 },
    };
}

fn isTrusted(addr: []const u8, trusted: []const []const u8) bool {
    const a = parse(addr) orelse return false;
    for (trusted) |entry| {
        const slash = std.mem.indexOfScalar(u8, entry, '/');
        const net = parse(if (slash) |s| entry[0..s] else entry) orelse continue;
        if (net.len != a.len) continue;
        const bits: usize = if (slash) |s| std.fmt.parseInt(u8, entry[s + 1 ..], 10) catch continue else @as(usize, net.len) * 8;
        if (bits > @as(usize, net.len) * 8) continue;
        if (prefixEqual(a.bytes[0..a.len], net.bytes[0..net.len], bits)) return true;
    }
    return false;
}

fn prefixEqual(a: []const u8, b: []const u8, bits: usize) bool {
    const full = bits / 8;
    if (!std.mem.eql(u8, a[0..full], b[0..full])) return false;
    const rem: u3 = @intCast(bits % 8);
    if (rem == 0) return true;
    const mask: u8 = @as(u8, 0xff) << @intCast(8 - @as(u4, rem));
    return (a[full] & mask) == (b[full] & mask);
}

const t = std.testing;

test "clientIp: no trusted proxies — the header is ignored" {
    try t.expectEqualStrings("203.0.113.7", resolve("203.0.113.7", "1.2.3.4", &.{}).?);
    try t.expectEqualStrings("10.0.0.2", resolve("10.0.0.2", "1.2.3.4", &.{}).?);
}

test "clientIp: an untrusted peer can't spoof through the header" {
    try t.expectEqualStrings("198.51.100.9", resolve("198.51.100.9", "1.2.3.4", &.{"10.0.0.0/8"}).?);
}

test "clientIp: trusted peer — first untrusted hop from the right" {
    const tr = &[_][]const u8{ "10.0.0.0/8", "172.16.0.0/12" };
    try t.expectEqualStrings("203.0.113.7", resolve("10.0.0.2", "203.0.113.7", tr).?);
    // A client-supplied first entry is skipped: the proxy appended the real one.
    try t.expectEqualStrings("203.0.113.7", resolve("10.0.0.2", "6.6.6.6, 203.0.113.7", tr).?);
    // Two proxy hops.
    try t.expectEqualStrings("203.0.113.7", resolve("10.0.0.2", "203.0.113.7, 172.16.5.4", tr).?);
    // All trusted: the leftmost.
    try t.expectEqualStrings("10.1.1.1", resolve("10.0.0.2", "10.1.1.1, 10.0.0.3", tr).?);
    // No header: the peer.
    try t.expectEqualStrings("10.0.0.2", resolve("10.0.0.2", null, tr).?);
    // Garbage in the header: the peer, not a guess.
    try t.expectEqualStrings("10.0.0.2", resolve("10.0.0.2", "not-an-ip", tr).?);
}

test "clientIp: IPv6, single addresses and prefix edges" {
    try t.expectEqualStrings("2001:db8::1", resolve("fd00::5", "2001:db8::1", &.{"fd00::/8"}).?);
    try t.expectEqualStrings("203.0.113.7", resolve("127.0.0.1", "203.0.113.7", &.{"127.0.0.1"}).?);
    try t.expect(isTrusted("172.31.255.255", &.{"172.16.0.0/12"}));
    try t.expect(!isTrusted("172.32.0.1", &.{"172.16.0.0/12"}));
    try t.expect(!isTrusted("10.0.0.1", &.{"fd00::/8"}));
    try t.expect(resolve(null, "1.2.3.4", &.{}) == null);
}
