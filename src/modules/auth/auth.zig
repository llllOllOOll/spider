//! HS256 tokens and the older cookie login (`spider.auth`): signing and
//! checking a JWT with a shared secret, helpers for a cookie named "token",
//! and the `Auth` middleware over them. New apps use `spider.session`, which
//! signs and verifies with `jwtSign` and `jwtPayload` from this file.

const std = @import("std");
const Ctx = @import("../../core/context.zig").Ctx;
const Response = @import("../../core/context.zig").Response;
const MiddlewareFn = @import("../../core/context.zig").MiddlewareFn;
const NextFn = @import("../../core/context.zig").NextFn;

// ─── JWT ────────────────────────────────────────────────────────────────────

/// The claims the `Auth` middleware expects in a token: a numeric user id,
/// email, name and expiry. Sign one with `jwtSign(alloc, Claims{...}, secret)`.
pub const Claims = struct {
    /// The user id.
    sub: i32,
    email: []const u8,
    name: []const u8,
    /// Expiry, in seconds since the epoch. 0 or less: `jwtVerify` never treats
    /// the token as expired.
    exp: i64,
};

/// What checking a token fails with.
pub const JwtError = error{
    /// Not three parts, not an HS256 header as `jwtSign` writes it, or a
    /// payload that is not the expected claims.
    InvalidFormat,
    /// Signed with another secret, or changed after signing.
    InvalidSignature,
    /// `exp` is in the past.
    Expired,
};

const HEADER_B64 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

/// A token (JWT, HS256) carrying `claims`, signed with `secret`. `claims` is
/// any struct that serializes to JSON; nothing is added to it, so put `exp`
/// in it yourself. The caller owns the result (allocated with `alloc`).
///
/// ```zig
/// const token = try spider.auth.jwtSign(c.arena, .{ .sub = "7", .exp = expires }, secret);
/// ```
pub fn jwtSign(alloc: std.mem.Allocator, claims: anytype, secret: []const u8) ![]u8 {
    const payload_json = try std.json.Stringify.valueAlloc(alloc, claims, .{});
    defer alloc.free(payload_json);

    const payload_b64_len = std.base64.url_safe_no_pad.Encoder.calcSize(payload_json.len);
    const payload_b64_buf = try alloc.alloc(u8, payload_b64_len);
    defer alloc.free(payload_b64_buf);
    const payload_b64 = std.base64.url_safe_no_pad.Encoder.encode(payload_b64_buf, payload_json);

    const signing_input = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ HEADER_B64, payload_b64 });
    defer alloc.free(signing_input);

    var hmac_output: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&hmac_output, signing_input, secret);

    var sig_b64_buf: [64]u8 = undefined;
    const sig_b64 = std.base64.url_safe_no_pad.Encoder.encode(&sig_b64_buf, &hmac_output);

    return std.fmt.allocPrint(alloc, "{s}.{s}.{s}", .{ HEADER_B64, payload_b64, sig_b64 });
}

/// The JSON payload of `token` once its HS256 signature is checked against
/// `secret`; the caller owns it. Does not look at the claims (not at `exp`
/// either): jwtVerify and spider.session do. Errors:
/// `JwtError.InvalidFormat` (not three parts, a header other than the one
/// `jwtSign` writes, a payload that is not base64url) and
/// `JwtError.InvalidSignature`.
pub fn jwtPayload(alloc: std.mem.Allocator, token: []const u8, secret: []const u8) ![]u8 {
    var parts = std.mem.splitScalar(u8, token, '.');
    const header_b64 = parts.next() orelse return JwtError.InvalidFormat;
    const payload_b64 = parts.next() orelse return JwtError.InvalidFormat;
    const sig_b64 = parts.next() orelse return JwtError.InvalidFormat;
    if (parts.next() != null) return JwtError.InvalidFormat;
    if (!std.mem.eql(u8, header_b64, HEADER_B64)) return JwtError.InvalidFormat;

    var recomputed: [32]u8 = undefined;
    var mac = std.crypto.auth.hmac.sha2.HmacSha256.init(secret);
    mac.update(header_b64);
    mac.update(".");
    mac.update(payload_b64);
    mac.final(&recomputed);

    var sent: [32]u8 = undefined;
    const sig_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(sig_b64) catch return JwtError.InvalidFormat;
    if (sig_len != 32) return JwtError.InvalidSignature;
    std.base64.url_safe_no_pad.Decoder.decode(&sent, sig_b64) catch return JwtError.InvalidSignature;
    if (!std.crypto.timing_safe.eql([32]u8, sent, recomputed)) return JwtError.InvalidSignature;

    const len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload_b64) catch return JwtError.InvalidFormat;
    const payload = try alloc.alloc(u8, len);
    errdefer alloc.free(payload);
    std.base64.url_safe_no_pad.Decoder.decode(payload, payload_b64) catch return JwtError.InvalidFormat;
    return payload;
}

test "jwtPayload: the payload of a token signed with the secret, nothing else" {
    const a = std.testing.allocator;
    const token = try jwtSign(a, .{ .sub = "7", .exp = 1 }, "secret");
    defer a.free(token);

    const payload = try jwtPayload(a, token, "secret");
    defer a.free(payload);
    try std.testing.expectEqualStrings("{\"sub\":\"7\",\"exp\":1}", payload);

    try std.testing.expectError(JwtError.InvalidSignature, jwtPayload(a, token, "other secret"));
    try std.testing.expectError(JwtError.InvalidFormat, jwtPayload(a, "not.a.token.at.all", "secret"));
    try std.testing.expectError(JwtError.InvalidFormat, jwtPayload(a, "onlyonepart", "secret"));

    // The same token with one byte of the payload changed.
    const forged = try a.dupe(u8, token);
    defer a.free(forged);
    const dot = std.mem.indexOfScalar(u8, forged, '.').?;
    forged[dot + 3] = if (forged[dot + 3] == 'A') 'B' else 'A';
    try std.testing.expectError(JwtError.InvalidSignature, jwtPayload(a, forged, "secret"));
}

/// Checks the signature of `token` and its `exp`, and returns its payload
/// parsed as `T` (a struct with at least `sub` and `exp`).
///
/// Safe with `T = Claims`, or a `T` whose only strings are fields named
/// `email`, `name` and `locale`: those three (which must be `[]const u8`)
/// are copied with `alloc`. Every other string or slice of the result (a
/// string `sub`, a list of roles, the strings of a nested struct) points
/// into memory that is freed before this function returns. For your own
/// claims use `jwtPayload` and parse the payload yourself, as
/// `spider.session` does.
///
/// With `Claims`, `email` and `name` are copies allocated with `alloc` (the
/// caller owns them). The header must be, byte for byte, the one `jwtSign`
/// writes: an HS256 token another library signed with the same secret can
/// fail here. Errors: `JwtError.InvalidFormat` (also when the payload has a
/// field `T` does not, or lacks one it requires),
/// `JwtError.InvalidSignature`, `JwtError.Expired` (`exp` greater than 0 and
/// earlier than the current second; a token is still accepted during the
/// second its `exp` names).
pub fn jwtVerify(comptime T: type, alloc: std.mem.Allocator, io: std.Io, token: []const u8, secret: []const u8) !T {
    if (!@hasField(T, "sub")) @compileError("Claims must have 'sub' field");
    if (!@hasField(T, "exp")) @compileError("Claims must have 'exp' field");

    var parts = std.mem.splitScalar(u8, token, '.');
    const header_b64 = parts.next() orelse return JwtError.InvalidFormat;
    const payload_b64 = parts.next() orelse return JwtError.InvalidFormat;
    const sig_b64 = parts.next() orelse return JwtError.InvalidFormat;
    if (parts.next() != null) return JwtError.InvalidFormat;

    if (!std.mem.eql(u8, header_b64, HEADER_B64)) return JwtError.InvalidFormat;

    const signing_input = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ header_b64, payload_b64 });
    defer alloc.free(signing_input);

    var recomputed: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&recomputed, signing_input, secret);

    var expected_bytes: [32]u8 = undefined;
    const decoded_sig_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(sig_b64) catch return JwtError.InvalidFormat;
    if (decoded_sig_len != 32) return JwtError.InvalidSignature;
    std.base64.url_safe_no_pad.Decoder.decode(&expected_bytes, sig_b64) catch return JwtError.InvalidSignature;
    if (!std.crypto.timing_safe.eql([32]u8, expected_bytes, recomputed)) return JwtError.InvalidSignature;

    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload_b64) catch return JwtError.InvalidFormat;
    const payload_json_buf = try alloc.alloc(u8, decoded_len);
    defer alloc.free(payload_json_buf);
    std.base64.url_safe_no_pad.Decoder.decode(payload_json_buf, payload_b64) catch return JwtError.InvalidFormat;

    // A validly signed payload that isn't the expected claims is still an
    // unusable token (401), not a server error.
    var parsed = std.json.parseFromSlice(T, alloc, payload_json_buf[0..decoded_len], .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return JwtError.InvalidFormat,
    };
    defer parsed.deinit();

    // Check the expiry
    if (@hasField(T, "exp")) {
        const now = std.Io.Clock.now(.real, io);
        const now_sec: i64 = @intCast(@divFloor(now.nanoseconds, 1_000_000_000));
        if (parsed.value.exp > 0 and parsed.value.exp < now_sec) {
            return JwtError.Expired;
        }
    }

    if (T == Claims) {
        return Claims{
            .sub = parsed.value.sub,
            .email = try alloc.dupe(u8, parsed.value.email),
            .name = try alloc.dupe(u8, parsed.value.name),
            .exp = parsed.value.exp,
        };
    }

    var result = parsed.value;
    if (@hasField(T, "email")) {
        result.email = try alloc.dupe(u8, parsed.value.email);
        errdefer alloc.free(result.email);
    }
    if (@hasField(T, "name")) {
        result.name = try alloc.dupe(u8, parsed.value.name);
        errdefer alloc.free(result.name);
    }
    if (@hasField(T, "locale")) {
        result.locale = try alloc.dupe(u8, parsed.value.locale);
        errdefer alloc.free(result.locale);
    }

    return result;
}

// ─── Cookie ─────────────────────────────────────────────────────────────────

/// The cookie the `cookie*` helpers below write and read.
pub const COOKIE_NAME = "token";

/// A `Set-Cookie` value that stores `token` in the "token" cookie: HttpOnly,
/// SameSite=Lax, Path=/, one day, without `Secure`. The caller owns it.
pub fn cookieSet(alloc: std.mem.Allocator, token: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{s}={s}; HttpOnly; SameSite=Lax; Path=/; Max-Age=86400",
        .{ COOKIE_NAME, token },
    );
}

/// `cookieSet`, with the `Secure` attribute when `secure` is true.
pub fn cookieSetSecure(alloc: std.mem.Allocator, token: []const u8, secure: bool) ![]u8 {
    if (secure) {
        return std.fmt.allocPrint(
            alloc,
            "{s}={s}; HttpOnly; SameSite=Lax; Path=/; Max-Age=86400; Secure",
            .{ COOKIE_NAME, token },
        );
    }
    return cookieSet(alloc, token);
}

/// The token in a `Cookie` request header value, or null when it has no
/// "token" cookie. A slice of `cookie_header`, not a copy.
pub fn cookieGet(cookie_header: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, cookie_header, ';');
    while (it.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " ");
        if (std.mem.startsWith(u8, trimmed, COOKIE_NAME ++ "=")) {
            return trimmed[COOKIE_NAME.len + 1 ..];
        }
    }
    return null;
}

/// A `Set-Cookie` value that empties and expires the "token" cookie (to log
/// out). The caller owns it.
///
/// ```zig
/// const cookie = try spider.auth.cookieClear(c.arena);
/// ```
pub fn cookieClear(alloc: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{s}=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0",
        .{COOKIE_NAME},
    );
}

// ─── Middleware ──────────────────────────────────────────────────────────────

/// What `Auth.init` takes.
pub const AuthConfig = struct {
    /// What the tokens were signed with (`jwtSign`). No default.
    secret: []const u8,
    /// Paths let through without a token: an exact match, or a prefix
    /// when the entry ends in `*` ("/assets/*" covers everything that
    /// starts with "/assets/"). Compared with the path of the request; its
    /// query string is ignored ("/login" also lets "/login?next=/x"
    /// through). Routes marked `.public` pass too. Default: none.
    public_paths: []const []const u8 = &.{},
    /// Cookie the middleware reads the token from. The `cookie*` helpers
    /// always use "token", whatever is set here.
    cookie_name: []const u8 = COOKIE_NAME,
    /// Where a request without a valid token is redirected.
    redirect_to: []const u8 = "/login",
    /// Not read by anything today.
    secure_cookie: bool = true,
};

/// Whether `target` (a request target: the path, and the query string
/// when there is one) is one of `public_paths`. An entry is a path, or a
/// prefix ending in `*`.
fn isPublicPath(public_paths: []const []const u8, target: []const u8) bool {
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
    for (public_paths) |public_path| {
        if (std.mem.eql(u8, path, public_path)) return true;
        if (std.mem.endsWith(u8, public_path, "*")) {
            const prefix = public_path[0 .. public_path.len - 1];
            if (std.mem.startsWith(u8, path, prefix)) return true;
        }
    }
    return false;
}

/// The middleware of the cookie login: a request whose cookie holds a valid
/// `Claims` token goes on, with the user in the params `_user_id`,
/// `_user_email` and `_user_name` (`c.userId()` reads the first); any other
/// request is redirected (302) to `redirect_to`, except on a route marked
/// `.public` or a path in `public_paths`, which pass without a check. The
/// `Authorization` header is not read.
pub const Auth = struct {
    /// The config given to `init`. Its strings are not copied.
    config: AuthConfig,

    /// Keeps `config`; nothing is allocated.
    pub fn init(config: AuthConfig) Auth {
        return .{ .config = config };
    }

    /// The check itself. Not a `MiddlewareFn` (it takes `self`): give
    /// `asFn()` to `server.use`.
    pub fn middleware(self: *const Auth, c: *Ctx, next: NextFn) !Response {
        if (c.route().public) return next(c);
        if (isPublicPath(self.config.public_paths, c.getPath())) return next(c);

        const token = c.cookie(self.config.cookie_name) orelse
            return c.redirect(self.config.redirect_to);

        const claims = jwtVerify(Claims, c.arena, c._io, token, self.config.secret) catch
            return c.redirect(self.config.redirect_to);

        const user_id_str = try std.fmt.allocPrint(c.arena, "{d}", .{claims.sub});
        const email_dup = try c.arena.dupe(u8, claims.email);
        const name_dup = try c.arena.dupe(u8, claims.name);

        try c.params.put(c.arena, try c.arena.dupe(u8, "_user_id"), user_id_str);
        try c.params.put(c.arena, try c.arena.dupe(u8, "_user_email"), email_dup);
        try c.params.put(c.arena, try c.arena.dupe(u8, "_user_name"), name_dup);

        return next(c);
    }

    /// The middleware to register: `server.use(auth.asFn())`. It keeps a
    /// pointer to this Auth, which must stay valid while the server runs, in
    /// one static slot: a process can use one Auth; a second call replaces
    /// the first.
    pub fn asFn(self: *const Auth) MiddlewareFn {
        const S = struct {
            // Written once during setup (single thread), then only read
            // by the worker threads.
            var instance: ?*const Auth = null;

            fn mw(c: *Ctx, next: NextFn) anyerror!Response {
                return instance.?.middleware(c, next);
            }
        };
        S.instance = self;
        @import("../auth_marker.zig").mark(S.mw);
        return S.mw;
    }
};

test "jwtVerify: a signed token whose payload isn't the claims is InvalidFormat (401), not a parse error" {
    const a = std.testing.allocator;
    const secret = "s3cret";
    const payload = "bm90IGpzb24"; // base64url("not json")
    const signing_input = try std.fmt.allocPrint(a, "{s}.{s}", .{ HEADER_B64, payload });
    defer a.free(signing_input);
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, signing_input, secret);
    var sig_buf: [64]u8 = undefined;
    const sig = std.base64.url_safe_no_pad.Encoder.encode(&sig_buf, &mac);
    const token = try std.fmt.allocPrint(a, "{s}.{s}", .{ signing_input, sig });
    defer a.free(token);
    try std.testing.expectError(error.InvalidFormat, jwtVerify(Claims, a, std.testing.io, token, secret));
    try std.testing.expectError(error.InvalidSignature, jwtVerify(Claims, a, std.testing.io, token, "other"));
}

test "isPublicPath: the query string does not make a public path private" {
    const paths = [_][]const u8{ "/login", "/assets/*" };
    try std.testing.expect(isPublicPath(&paths, "/login"));
    try std.testing.expect(isPublicPath(&paths, "/login?next=/dashboard"));
    try std.testing.expect(isPublicPath(&paths, "/assets/app.css?v=3"));
    try std.testing.expect(!isPublicPath(&paths, "/dashboard"));
    try std.testing.expect(!isPublicPath(&paths, "/dashboard?x=/login"));
    try std.testing.expect(!isPublicPath(&paths, "/loginx"));
}
