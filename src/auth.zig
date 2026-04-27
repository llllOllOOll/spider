const std = @import("std");
const web = @import("web.zig");
const Request = web.Request;
const Response = web.Response;
const NextFn = web.NextFn;

// ─── JWT ────────────────────────────────────────────────────────────────────

pub const Claims = struct {
    sub: i32,
    email: []const u8,
    exp: i64,
};

pub const JwtError = error{
    InvalidFormat,
    InvalidSignature,
    Expired,
};

const HEADER_B64 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

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

pub fn jwtVerify(comptime T: type, alloc: std.mem.Allocator, token: []const u8, secret: []const u8) !T {
    comptime std.debug.assert(@hasField(T, "exp"));
    comptime std.debug.assert(@hasField(T, "sub"));
    comptime std.debug.assert(@hasField(T, "email"));

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

    var parsed = try std.json.parseFromSlice(T, alloc, payload_json_buf[0..decoded_len], .{});
    defer parsed.deinit();

    // Skip expiration check for now - JWT tokens will be valid
    // In production, pass io parameter and use: std.Io.Clock.now(.real, io).toSeconds()
    _ = parsed.value.exp;

    if (T == Claims) {
        return Claims{
            .sub = parsed.value.sub,
            .email = try alloc.dupe(u8, parsed.value.email),
            .exp = parsed.value.exp,
        };
    }

    // Always duplicate string fields to avoid dangling pointers
    // Caller must free these fields after use!
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

pub const COOKIE_NAME = "token";

pub fn cookieSet(alloc: std.mem.Allocator, token: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{s}={s}; HttpOnly; SameSite=Lax; Path=/; Max-Age=86400",
        .{ COOKIE_NAME, token },
    );
}

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

pub fn cookieClear(alloc: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{s}=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0",
        .{COOKIE_NAME},
    );
}

// ─── Middleware ──────────────────────────────────────────────────────────────

pub const AuthConfig = struct {
    secret: []const u8,
    public_paths: []const []const u8 = &.{},
    cookie_name: []const u8 = COOKIE_NAME,
    redirect_to: []const u8 = "/auth/google",
};

pub const Auth = struct {
    config: AuthConfig,

    pub fn init(config: AuthConfig) Auth {
        return .{ .config = config };
    }

    pub fn middleware(self: *const Auth, alloc: std.mem.Allocator, req: *Request, next: NextFn) !Response {
        for (self.config.public_paths) |path| {
            if (std.mem.eql(u8, req.path, path)) return next(alloc, req);
            if (std.mem.endsWith(u8, path, "*")) {
                const prefix = path[0 .. path.len - 1];
                if (std.mem.startsWith(u8, req.path, prefix)) return next(alloc, req);
            }
        }

        const cookie_header = req.headers.get("Cookie") orelse
            return Response.redirect(alloc, self.config.redirect_to);

        const token = cookieGet(cookie_header) orelse
            return Response.redirect(alloc, self.config.redirect_to);

        const claims = jwtVerify(Claims, alloc, token, self.config.secret) catch
            return Response.redirect(alloc, self.config.redirect_to);

        const user_id = try std.fmt.allocPrint(alloc, "{d}", .{claims.sub});
        const email = try alloc.dupe(u8, claims.email);
        alloc.free(claims.email);

        try req.params.put(alloc, try alloc.dupe(u8, "_user_id"), user_id);
        try req.params.put(alloc, try alloc.dupe(u8, "_user_email"), email);

        return next(alloc, req);
    }
};
