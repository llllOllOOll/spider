//! `spider.push`: Web Push. Sends an encrypted notification to a browser's
//! push subscription (RFC 8291, `aes128gcm`), signed with the app's VAPID
//! keys (RFC 8292).

const std = @import("std");
const pacman = @import("pacman");
const Ctx = @import("../core/context.zig").Ctx;

const crypto = std.crypto;
const HmacSha256 = crypto.auth.hmac.sha2.HmacSha256;
const HkdfSha256 = crypto.kdf.hkdf.HkdfSha256;
const Aes128Gcm = crypto.aead.aes_gcm.Aes128Gcm;
const EcdsaP256Sha256 = crypto.sign.ecdsa.EcdsaP256Sha256;
const P256 = crypto.ecc.P256;

// ─── Types ─────────────────────────────────────────────────────────

/// A new VAPID key pair as raw bytes, from `WebPush.generateKeys`. To use it
/// in a `PushConfig` (or in the environment), encode each key as base64url
/// without padding.
pub const VapidKeys = struct {
    /// The P-256 private scalar, big-endian.
    private_key: [32]u8,
    /// The P-256 public point, uncompressed (it starts with 0x04).
    public_key: [65]u8,
};

/// The identity the app sends pushes with.
pub const PushConfig = struct {
    /// The contact a push service may use, as a `mailto:` or `https:` URL. It goes in the `sub` claim.
    subject: []const u8,
    /// The VAPID private key: the 32 bytes, base64url without padding.
    private_key: []const u8,
    /// The VAPID public key: the 65 bytes, base64url without padding. It is the
    /// `applicationServerKey` the page subscribes with, and is sent as it is.
    public_key: []const u8,
};

/// One browser subscription, with the three values of the browser's
/// `PushSubscription.toJSON()`. The app stores them when the user subscribes.
pub const PushSubscription = struct {
    /// The push service URL of this subscription.
    endpoint: []const u8,
    /// The browser's public key (`keys.p256dh`): 65 bytes, base64url without padding.
    p256dh: []const u8,
    /// The authentication secret (`keys.auth`): 16 bytes, base64url without padding.
    auth: []const u8,
};

// ─── WebPush Client ────────────────────────────────────────────────

/// The Web Push sender.
///
/// ```zig
/// const wp = spider.push.WebPush.initFromEnv();
/// try wp.sendRaw(arena, io, .{
///     .endpoint = s.endpoint,
///     .p256dh = s.p256dh,
///     .auth = s.auth,
/// }, payload, 86400);
/// ```
pub const WebPush = struct {
    config: PushConfig,

    /// A sender with the given keys. `config` is not copied: its strings must outlive the sender.
    pub fn init(config: PushConfig) WebPush {
        return .{ .config = config };
    }

    /// A sender configured from the variables `VAPID_SUBJECT`,
    /// `VAPID_PRIVATE_KEY` and `VAPID_PUBLIC_KEY` (the environment or `.env`).
    /// A variable that is not set becomes an empty string.
    pub fn initFromEnv() WebPush {
        const env = @import("../internal/env.zig");
        return init(.{
            .subject = env.getOr("VAPID_SUBJECT", ""),
            .private_key = env.getOr("VAPID_PRIVATE_KEY", ""),
            .public_key = env.getOr("VAPID_PUBLIC_KEY", ""),
        });
    }

    /// A new random VAPID key pair. Generate it once and keep it: subscriptions are tied to the public key.
    pub fn generateKeys(io: std.Io) VapidKeys {
        const private_key = P256.scalar.random(io, .big);
        const public_key = P256.basePoint.mul(private_key, .big) catch unreachable;
        return .{
            .private_key = private_key,
            .public_key = public_key.toUncompressedSec1(),
        };
    }

    /// Encrypts `payload` for `subscription` and posts it to the subscription's
    /// push service, outside a request (a job, a boot hook). `ttl` is how many
    /// seconds the push service keeps the message for a device that is offline.
    /// The message is sent with `Urgency: high`. Everything is allocated in
    /// `arena`.
    ///
    /// Fails with `error.PushSubscriptionExpired` when the service answers 410
    /// (delete the subscription), `error.PushForbidden` for 403 (the VAPID keys
    /// are not the ones the subscription was made with), `error.PushSendFailed`
    /// for any other status that is not 200, 201 or 204, and with the HTTP
    /// client's error when the service cannot be reached.
    pub fn sendRaw(
        self: *const WebPush,
        arena: std.mem.Allocator,
        io: std.Io,
        subscription: PushSubscription,
        payload: []const u8,
        ttl: u32,
    ) !void {
        const encrypted = try encryptPayload(arena, io, subscription, payload);
        const audience = try extractOrigin(arena, subscription.endpoint);
        const jwt = try buildVapidJwt(arena, io, self.config, audience);
        const pub_key_b64 = self.config.public_key;

        var res = try pacman.post(io, arena, subscription.endpoint, .{
            .body = .{ .raw = encrypted },
            .headers = &.{
                .{ .name = "Authorization", .value = try std.fmt.allocPrint(arena, "vapid t={s},k={s}", .{ jwt, pub_key_b64 }) },
                .{ .name = "Content-Encoding", .value = "aes128gcm" },
                .{ .name = "Content-Type", .value = "application/octet-stream" },
                .{ .name = "TTL", .value = try std.fmt.allocPrint(arena, "{d}", .{ttl}) },
                .{ .name = "Urgency", .value = "high" },
            },
        });
        defer res.deinit();

        if (res.status != .ok and res.status != .no_content and res.status != .created) {
            return switch (res.status) {
                .gone => error.PushSubscriptionExpired,
                .forbidden => error.PushForbidden,
                else => error.PushSendFailed,
            };
        }
    }

    /// `sendRaw` from a handler: it uses the request's arena and Io, and logs a
    /// refused push at `err` level with the status and the endpoint. Same errors.
    pub fn send(
        self: *const WebPush,
        c: *Ctx,
        subscription: PushSubscription,
        payload: []const u8,
        ttl: u32,
    ) !void {
        const encrypted = try encryptPayload(c.arena, c._io, subscription, payload);
        const audience = try extractOrigin(c.arena, subscription.endpoint);
        const jwt = try buildVapidJwt(c.arena, c._io, self.config, audience);
        const pub_key_b64 = self.config.public_key;

        var res = try pacman.post(c._io, c.arena, subscription.endpoint, .{
            .body = .{ .raw = encrypted },
            .headers = &.{
                .{ .name = "Authorization", .value = try std.fmt.allocPrint(c.arena, "vapid t={s},k={s}", .{ jwt, pub_key_b64 }) },
                .{ .name = "Content-Encoding", .value = "aes128gcm" },
                .{ .name = "Content-Type", .value = "application/octet-stream" },
                .{ .name = "TTL", .value = try std.fmt.allocPrint(c.arena, "{d}", .{ttl}) },
                .{ .name = "Urgency", .value = "high" },
            },
        });
        defer res.deinit();

        if (res.status != .ok and res.status != .no_content and res.status != .created) {
            std.log.err("push send failed status={d} endpoint={s}", .{ @intFromEnum(res.status), subscription.endpoint });
            return switch (res.status) {
                .gone => error.PushSubscriptionExpired, // 410 — subscription permanently invalid
                .forbidden => error.PushForbidden, // 403 — VAPID key mismatch or wrong origin
                else => error.PushSendFailed,
            };
        }
    }
};

// ─── Payload Encryption (RFC 8291) ───────────────────────────────

const RS: u32 = 4096;

fn encryptPayload(
    allocator: std.mem.Allocator,
    io: std.Io,
    subscription: PushSubscription,
    payload: []const u8,
) ![]u8 {
    // 1. Decode subscription keys
    var ua_public: [65]u8 = undefined;
    try base64urlDecode(&ua_public, subscription.p256dh);

    var auth_secret: [16]u8 = undefined;
    try base64urlDecode(&auth_secret, subscription.auth);

    // 2. Generate ephemeral keypair
    const eph_private = P256.scalar.random(io, .big);
    const eph_public = try P256.basePoint.mul(eph_private, .big);

    // 3. ECDH shared secret
    const ua_point = try P256.fromSec1(&ua_public);
    const shared_point = try ua_point.mul(eph_private, .big);
    const ecdh_secret = shared_point.affineCoordinates().x.toBytes(.big);

    // 4. Generate random salt
    var salt: [16]u8 = undefined;
    io.random(&salt);

    // 5. Combine ECDH and auth secrets: PRK_key = HMAC-SHA256(auth_secret, ecdh_secret)
    const prk_key = HkdfSha256.extract(&auth_secret, &ecdh_secret);

    // 6. Expand: key_info = "WebPush: info" || 0x00 || ua_public || as_public
    const eph_pub_sec1 = eph_public.toUncompressedSec1();
    const key_info = try std.mem.concat(allocator, u8, &.{
        "WebPush: info\x00",
        &ua_public,
        &eph_pub_sec1,
    });
    defer allocator.free(key_info);

    var ikm: [32]u8 = undefined;
    HkdfSha256.expand(&ikm, key_info, prk_key);

    // 7. PRK = HKDF-Extract(salt, IKM)
    const prk = HkdfSha256.extract(&salt, &ikm);

    // 8. CEK = HKDF-Expand(PRK, "Content-Encoding: aes128gcm\0", 16)
    var cek: [16]u8 = undefined;
    HkdfSha256.expand(&cek, "Content-Encoding: aes128gcm\x00", prk);

    // 9. Nonce = HKDF-Expand(PRK, "Content-Encoding: nonce\0", 12)
    var nonce: [12]u8 = undefined;
    HkdfSha256.expand(&nonce, "Content-Encoding: nonce\x00", prk);

    // 10. Encrypt with AES-128-GCM - append padding delimiter 0x02
    const plaintext = try std.mem.concat(allocator, u8, &.{ payload, &[_]u8{0x02} });
    defer allocator.free(plaintext);
    const ciphertext = try allocator.alloc(u8, plaintext.len);
    defer allocator.free(ciphertext);
    var tag: [Aes128Gcm.tag_length]u8 = undefined;
    Aes128Gcm.encrypt(ciphertext, &tag, plaintext, "", nonce, cek);

    // 11. Build body: salt(16) | rs(4 BE) | keyid_len(1) | keyid(65) | ciphertext | tag(16)
    var body = try std.ArrayList(u8).initCapacity(allocator, 16 + 4 + 1 + 65 + ciphertext.len + 16);
    try body.appendSlice(allocator, &salt);
    try body.appendSlice(allocator, std.mem.asBytes(&std.mem.nativeToBig(u32, RS)));
    try body.appendSlice(allocator, &.{65});
    try body.appendSlice(allocator, &eph_pub_sec1);
    try body.appendSlice(allocator, ciphertext);
    try body.appendSlice(allocator, &tag);

    return body.toOwnedSlice(allocator);
}

// ─── VAPID JWT (RFC 8292) ─────────────────────────────────────────

fn buildVapidJwt(
    allocator: std.mem.Allocator,
    _: std.Io,
    config: PushConfig,
    audience: []const u8,
) ![]const u8 {
    var private_key_bytes: [32]u8 = undefined;
    try base64urlDecode(&private_key_bytes, config.private_key);

    const header_b64 = try base64urlEncode(allocator, "{\"typ\":\"JWT\",\"alg\":\"ES256\"}");
    defer allocator.free(header_b64);

    const exp = timestampSec() + 43200;
    const payload_str = try std.fmt.allocPrint(allocator, "{{\"aud\":\"{s}\",\"exp\":{d},\"sub\":\"{s}\"}}", .{
        audience, exp, config.subject,
    });
    defer allocator.free(payload_str);
    const payload_b64 = try base64urlEncode(allocator, payload_str);
    defer allocator.free(payload_b64);

    const signing_input = try std.mem.concat(allocator, u8, &.{ header_b64, ".", payload_b64 });
    defer allocator.free(signing_input);

    const secret_key = EcdsaP256Sha256.SecretKey{ .bytes = private_key_bytes };
    const key_pair = try EcdsaP256Sha256.KeyPair.fromSecretKey(secret_key);
    const sig = try key_pair.sign(signing_input, null);

    const sig_b64 = try base64urlEncode(allocator, &sig.toBytes());
    defer allocator.free(sig_b64);

    return std.mem.concat(allocator, u8, &.{ header_b64, ".", payload_b64, ".", sig_b64 });
}

// ─── Base64url ─────────────────────────────────────────────────────

fn base64urlEncode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const out_len = std.base64.url_safe_no_pad.Encoder.calcSize(data.len);
    const out = try allocator.alloc(u8, out_len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, data);
    return out;
}

fn base64urlDecode(dest: []u8, src: []const u8) !void {
    try std.base64.url_safe_no_pad.Decoder.decode(dest, src);
}

// ─── URL Helpers ──────────────────────────────────────────────────

fn extractOrigin(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(url);
    const port_str = if (uri.port) |p| try std.fmt.allocPrint(allocator, ":{d}", .{p}) else "";
    defer if (uri.port != null) allocator.free(port_str);
    const host_component = uri.host orelse return error.InvalidUri;
    const host_str = switch (host_component) {
        .raw => |r| r,
        .percent_encoded => |p| p,
    };
    return std.fmt.allocPrint(allocator, "{s}://{s}{s}", .{
        uri.scheme,
        host_str,
        port_str,
    });
}

fn timestampSec() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec));
}

// ─── Tests ─────────────────────────────────────────────────────────

test "base64url roundtrip" {
    const allocator = std.testing.allocator;
    const original = "hello world";
    const encoded = try base64urlEncode(allocator, original);
    defer allocator.free(encoded);
    var decoded: [11]u8 = undefined;
    try base64urlDecode(&decoded, encoded);
    try std.testing.expectEqualStrings(original, &decoded);
}

test "base64url no padding" {
    const allocator = std.testing.allocator;
    const encoded = try base64urlEncode(allocator, "f");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("Zg", encoded);
}

test "generate VAPID keys" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const keys = WebPush.generateKeys(io);
    try std.testing.expect(keys.private_key.len == 32);
    try std.testing.expect(keys.public_key.len == 65);
    try std.testing.expect(keys.public_key[0] == 0x04);
}

test "WebPush init and initFromEnv" {
    const wp = WebPush.init(.{
        .subject = "mailto:test@example.com",
        .private_key = "abc123",
        .public_key = "def456",
    });
    try std.testing.expectEqualStrings("mailto:test@example.com", wp.config.subject);
}

test "build JWT produces three dot-separated parts" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const allocator = std.testing.allocator;

    const keys = WebPush.generateKeys(io);
    const priv_b64 = try base64urlEncode(allocator, &keys.private_key);
    defer allocator.free(priv_b64);
    const pub_b64 = try base64urlEncode(allocator, &keys.public_key);
    defer allocator.free(pub_b64);

    const wp = WebPush.init(.{
        .subject = "mailto:admin@example.com",
        .private_key = priv_b64,
        .public_key = pub_b64,
    });

    const jwt = try buildVapidJwt(allocator, io, wp.config, "https://fcm.googleapis.com");
    defer allocator.free(jwt);

    var parts = std.mem.splitSequence(u8, jwt, ".");
    try std.testing.expect(parts.next() != null);
    try std.testing.expect(parts.next() != null);
    try std.testing.expect(parts.next() != null);
    try std.testing.expect(parts.next() == null);
}

test "encrypt payload produces valid body format" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const allocator = std.testing.allocator;

    const keys = WebPush.generateKeys(io);
    const priv_b64 = try base64urlEncode(allocator, &keys.private_key);
    defer allocator.free(priv_b64);
    const pub_b64 = try base64urlEncode(allocator, &keys.public_key);
    defer allocator.free(pub_b64);

    var auth_buf: [16]u8 = undefined;
    @memset(&auth_buf, 0x01);
    const auth_b64 = try base64urlEncode(allocator, &auth_buf);
    defer allocator.free(auth_b64);

    const sub = PushSubscription{
        .endpoint = "https://example.com/push",
        .p256dh = pub_b64,
        .auth = auth_b64,
    };

    const encrypted = try encryptPayload(allocator, io, sub, "Hello, world!");
    defer allocator.free(encrypted);

    // salt(16) + rs(4) + keyid_len(1) + keyid(65) + ciphertext + tag(16)
    try std.testing.expect(encrypted.len >= 16 + 4 + 1 + 65 + 16);
    // Check salt
    try std.testing.expect(encrypted[0..16].len == 16);
    // Check rs = 4096 = 0x1000
    const rs = std.mem.readInt(u32, encrypted[16..20], .big);
    try std.testing.expect(rs == 4096);
    // Check keyid length
    try std.testing.expect(encrypted[20] == 65);
    // Check keyid starts with 0x04 (uncompressed SEC1)
    try std.testing.expect(encrypted[21] == 0x04);
}

test "extractOrigin from HTTPS URL" {
    const allocator = std.testing.allocator;
    const origin = try extractOrigin(allocator, "https://fcm.googleapis.com/fcm/send/abc123");
    defer allocator.free(origin);
    try std.testing.expectEqualStrings("https://fcm.googleapis.com", origin);
}

test "extractOrigin from URL with port" {
    const allocator = std.testing.allocator;
    const origin = try extractOrigin(allocator, "https://example.com:8443/push");
    defer allocator.free(origin);
    try std.testing.expectEqualStrings("https://example.com:8443", origin);
}
