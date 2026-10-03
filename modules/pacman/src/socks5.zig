const std = @import("std");
const Io = std.Io;

/// Username/password credentials for SOCKS5 auth (RFC 1929).
pub const Auth = struct {
    username: []const u8,
    password: []const u8,
};

pub const Socks5Error = error{
    Socks5GreetingFailed,
    Socks5NoAcceptableAuthMethod,
    Socks5AuthFailed,
    Socks5ConnectFailed,
    Socks5UnexpectedReply,
    Socks5AddressTooLong,
};

// ─── Pure protocol framing (no I/O — unit-testable without a network) ─────

/// Builds the initial greeting + method-selection message (RFC 1928 §3).
/// `buf` must be at least 4 bytes.
pub fn encodeGreeting(buf: []u8, has_auth: bool) []const u8 {
    if (has_auth) {
        buf[0] = 0x05; // VER
        buf[1] = 0x02; // NMETHODS
        buf[2] = 0x00; // no-auth
        buf[3] = 0x02; // user/pass
        return buf[0..4];
    }
    buf[0] = 0x05;
    buf[1] = 0x01;
    buf[2] = 0x00;
    return buf[0..3];
}

/// Parses the server's method-selection reply (RFC 1928 §3). Returns the
/// chosen method byte (0x00 = no auth, 0x02 = user/pass, 0xFF = none
/// acceptable).
pub fn parseMethodSelection(reply: *const [2]u8) Socks5Error!u8 {
    if (reply[0] != 0x05) return error.Socks5GreetingFailed;
    return reply[1];
}

/// Builds the username/password sub-negotiation request (RFC 1929).
/// `buf` must be at least 515 bytes (1 + 1 + 255 + 1 + 255).
pub fn encodeAuthRequest(buf: []u8, auth: Auth) Socks5Error![]const u8 {
    if (auth.username.len > 255 or auth.password.len > 255) return error.Socks5AddressTooLong;
    var i: usize = 0;
    buf[i] = 0x01; // auth sub-negotiation version
    i += 1;
    buf[i] = @intCast(auth.username.len);
    i += 1;
    @memcpy(buf[i..][0..auth.username.len], auth.username);
    i += auth.username.len;
    buf[i] = @intCast(auth.password.len);
    i += 1;
    @memcpy(buf[i..][0..auth.password.len], auth.password);
    i += auth.password.len;
    return buf[0..i];
}

/// Parses the username/password sub-negotiation reply (RFC 1929).
pub fn parseAuthReply(reply: *const [2]u8) Socks5Error!void {
    if (reply[1] != 0x00) return error.Socks5AuthFailed;
}

/// Builds the CONNECT request (RFC 1928 §4) using address type 0x03 (domain
/// name) — this is the "5h" part: the hostname is sent raw to the proxy,
/// which resolves it itself. This client never resolves the target host
/// locally.
/// `buf` must be at least 262 bytes (4 + 1 + 255 + 2).
pub fn encodeConnectRequest(buf: []u8, target_host: []const u8, target_port: u16) Socks5Error![]const u8 {
    if (target_host.len > 255) return error.Socks5AddressTooLong;
    var i: usize = 0;
    buf[i] = 0x05; // VER
    buf[i + 1] = 0x01; // CMD = CONNECT
    buf[i + 2] = 0x00; // RSV
    buf[i + 3] = 0x03; // ATYP = domain name
    i += 4;
    buf[i] = @intCast(target_host.len);
    i += 1;
    @memcpy(buf[i..][0..target_host.len], target_host);
    i += target_host.len;
    buf[i] = @intCast(target_port >> 8);
    buf[i + 1] = @intCast(target_port & 0xff);
    i += 2;
    return buf[0..i];
}

/// Parses the fixed 4-byte header of a CONNECT reply (RFC 1928 §6): VER,
/// REP, RSV, ATYP. Does not consume the variable-length bound address that
/// follows — the caller reads that separately based on the returned ATYP.
pub fn parseConnectReplyHeader(header: *const [4]u8) Socks5Error!u8 {
    if (header[0] != 0x05) return error.Socks5UnexpectedReply;
    if (header[1] != 0x00) return error.Socks5ConnectFailed;
    return header[3]; // ATYP
}

// ─── I/O-driving handshake (needs a real or loopback connection) ──────────

/// Performs a full SOCKS5(h) handshake over an already-connected stream to
/// the proxy, tunneling to `target_host:target_port`. On success, `stream`
/// is a raw byte pipe directly to the target — the caller is responsible
/// for layering TLS (or using it plain) on top; this function never touches
/// TLS itself.
///
/// Known, unresolved limitation (same class of issue as
/// vendor/zig-lib-patched/PATCH_NOTES.md's Change 1): this reads the
/// handshake replies through a buffered `stream.reader()`, whose underlying
/// fill can pull more bytes from the socket than the exact handshake size in
/// a single recv() — e.g. if the proxy sends the CONNECT reply and the very
/// first tunneled bytes close together. Any such extra bytes end up sitting
/// in this function's local `read_buf` and are lost once it returns (only
/// `stream`, not the reader or its buffer, is handed to the caller). Not
/// observed in practice with well-behaved proxies, which don't pipeline
/// tunnel data ahead of the handshake completing.
pub fn connect(
    io: Io,
    stream: Io.net.Stream,
    target_host: []const u8,
    target_port: u16,
    auth: ?Auth,
) !void {
    var write_buf: [515]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    var read_buf: [262]u8 = undefined;
    var reader = stream.reader(io, &read_buf);

    var greeting_buf: [4]u8 = undefined;
    try writer.interface.writeAll(encodeGreeting(&greeting_buf, auth != null));
    try writer.interface.flush();

    var method_reply: [2]u8 = undefined;
    try reader.interface.readSliceAll(&method_reply);
    const method = try parseMethodSelection(&method_reply);

    switch (method) {
        0x00 => {},
        0x02 => {
            const a = auth orelse return error.Socks5NoAcceptableAuthMethod;
            var auth_buf: [515]u8 = undefined;
            try writer.interface.writeAll(try encodeAuthRequest(&auth_buf, a));
            try writer.interface.flush();

            var auth_reply: [2]u8 = undefined;
            try reader.interface.readSliceAll(&auth_reply);
            try parseAuthReply(&auth_reply);
        },
        else => return error.Socks5NoAcceptableAuthMethod,
    }

    var connect_buf: [262]u8 = undefined;
    try writer.interface.writeAll(try encodeConnectRequest(&connect_buf, target_host, target_port));
    try writer.interface.flush();

    var reply_header: [4]u8 = undefined;
    try reader.interface.readSliceAll(&reply_header);
    const atyp = try parseConnectReplyHeader(&reply_header);

    // Consume (and discard) the bound address + port — this client only
    // needs the tunnel established, the bound address is unused.
    switch (atyp) {
        0x01 => { // IPv4: 4 bytes addr + 2 bytes port
            var rest: [6]u8 = undefined;
            try reader.interface.readSliceAll(&rest);
        },
        0x04 => { // IPv6: 16 bytes addr + 2 bytes port
            var rest: [18]u8 = undefined;
            try reader.interface.readSliceAll(&rest);
        },
        0x03 => { // domain: 1 length byte, then that many bytes + 2 bytes port
            var len_buf: [1]u8 = undefined;
            try reader.interface.readSliceAll(&len_buf);
            var rest: [255 + 2]u8 = undefined;
            try reader.interface.readSliceAll(rest[0 .. @as(usize, len_buf[0]) + 2]);
        },
        else => return error.Socks5UnexpectedReply,
    }
}

// ─── Unit tests — pure framing, no network ────────────────────────────────

test "encodeGreeting without auth" {
    var buf: [4]u8 = undefined;
    const msg = encodeGreeting(&buf, false);
    try std.testing.expectEqualSlices(u8, &.{ 0x05, 0x01, 0x00 }, msg);
}

test "encodeGreeting with auth" {
    var buf: [4]u8 = undefined;
    const msg = encodeGreeting(&buf, true);
    try std.testing.expectEqualSlices(u8, &.{ 0x05, 0x02, 0x00, 0x02 }, msg);
}

test "parseMethodSelection accepts no-auth" {
    const reply = [2]u8{ 0x05, 0x00 };
    try std.testing.expectEqual(@as(u8, 0x00), try parseMethodSelection(&reply));
}

test "parseMethodSelection accepts user/pass" {
    const reply = [2]u8{ 0x05, 0x02 };
    try std.testing.expectEqual(@as(u8, 0x02), try parseMethodSelection(&reply));
}

test "parseMethodSelection rejects wrong version" {
    const reply = [2]u8{ 0x04, 0x00 };
    try std.testing.expectError(error.Socks5GreetingFailed, parseMethodSelection(&reply));
}

test "encodeAuthRequest frames username and password lengths" {
    var buf: [515]u8 = undefined;
    const msg = try encodeAuthRequest(&buf, .{ .username = "alice", .password = "secret" });
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 5 }, msg[0..2]);
    try std.testing.expectEqualStrings("alice", msg[2..7]);
    try std.testing.expectEqual(@as(u8, 6), msg[7]);
    try std.testing.expectEqualStrings("secret", msg[8..14]);
    try std.testing.expectEqual(@as(usize, 14), msg.len);
}

test "encodeAuthRequest rejects oversized credentials" {
    var buf: [515]u8 = undefined;
    const long: [256]u8 = @splat('a');
    try std.testing.expectError(error.Socks5AddressTooLong, encodeAuthRequest(&buf, .{ .username = &long, .password = "x" }));
}

test "parseAuthReply accepts success" {
    const reply = [2]u8{ 0x01, 0x00 };
    try parseAuthReply(&reply);
}

test "parseAuthReply rejects failure" {
    const reply = [2]u8{ 0x01, 0x01 };
    try std.testing.expectError(error.Socks5AuthFailed, parseAuthReply(&reply));
}

test "encodeConnectRequest frames a domain name target (5h mode)" {
    var buf: [262]u8 = undefined;
    const msg = try encodeConnectRequest(&buf, "example.com", 443);
    try std.testing.expectEqualSlices(u8, &.{ 0x05, 0x01, 0x00, 0x03 }, msg[0..4]);
    try std.testing.expectEqual(@as(u8, 11), msg[4]);
    try std.testing.expectEqualStrings("example.com", msg[5..16]);
    try std.testing.expectEqual(@as(u8, 0x01), msg[16]); // 443 >> 8
    try std.testing.expectEqual(@as(u8, 0xbb), msg[17]); // 443 & 0xff
    try std.testing.expectEqual(@as(usize, 18), msg.len);
}

test "encodeConnectRequest rejects oversized hostname" {
    var buf: [262]u8 = undefined;
    const long: [256]u8 = @splat('a');
    try std.testing.expectError(error.Socks5AddressTooLong, encodeConnectRequest(&buf, &long, 80));
}

test "parseConnectReplyHeader: success returns atyp" {
    const header = [4]u8{ 0x05, 0x00, 0x00, 0x01 };
    try std.testing.expectEqual(@as(u8, 0x01), try parseConnectReplyHeader(&header));
}

test "parseConnectReplyHeader: IPv6 atyp" {
    const header = [4]u8{ 0x05, 0x00, 0x00, 0x04 };
    try std.testing.expectEqual(@as(u8, 0x04), try parseConnectReplyHeader(&header));
}

test "parseConnectReplyHeader: domain atyp" {
    const header = [4]u8{ 0x05, 0x00, 0x00, 0x03 };
    try std.testing.expectEqual(@as(u8, 0x03), try parseConnectReplyHeader(&header));
}

test "parseConnectReplyHeader: connection refused" {
    const header = [4]u8{ 0x05, 0x05, 0x00, 0x01 };
    try std.testing.expectError(error.Socks5ConnectFailed, parseConnectReplyHeader(&header));
}

test "parseConnectReplyHeader: wrong version" {
    const header = [4]u8{ 0x04, 0x00, 0x00, 0x01 };
    try std.testing.expectError(error.Socks5UnexpectedReply, parseConnectReplyHeader(&header));
}
