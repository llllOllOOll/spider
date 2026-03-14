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

pub fn jwtSign(alloc: std.mem.Allocator, claims: Claims, secret: []const u8) ![]u8 {
    std.log.info("JWT: jwtSign start", .{});
    const payload_json = try std.fmt.allocPrint(
        alloc,
        "{{\"sub\":{d},\"email\":\"{s}\",\"exp\":{d}}}",
        .{ claims.sub, claims.email, claims.exp },
    );
    defer alloc.free(payload_json);
    std.log.info("JWT: payload created: {s}", .{payload_json});

    var payload_b64_buf: [512]u8 = undefined;
    const payload_b64 = std.base64.url_safe_no_pad.Encoder.encode(&payload_b64_buf, payload_json);
    std.log.info("JWT: payload_b64 created", .{});

    var signing_input_buf: [1024]u8 = undefined;
    const signing_input = try std.fmt.bufPrint(&signing_input_buf, "{s}.{s}", .{ HEADER_B64, payload_b64 });
    std.log.info("JWT: signing_input created, len={d}", .{signing_input.len});

    var hmac_output: [32]u8 = undefined;
    std.log.info("JWT: about to create HMAC with secret len={d}", .{secret.len});
    std.crypto.auth.hmac.sha2.HmacSha256.create(&hmac_output, signing_input, secret);
    std.log.info("JWT: HMAC created", .{});

    var sig_b64_buf: [64]u8 = undefined;
    const sig_b64 = std.base64.url_safe_no_pad.Encoder.encode(&sig_b64_buf, &hmac_output);

    return std.fmt.allocPrint(alloc, "{s}.{s}.{s}", .{ HEADER_B64, payload_b64, sig_b64 });
}

pub fn jwtVerify(alloc: std.mem.Allocator, token: []const u8, secret: []const u8) !Claims {
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

    var recomputed_b64_buf: [64]u8 = undefined;
    const recomputed_b64 = std.base64.url_safe_no_pad.Encoder.encode(&recomputed_b64_buf, &recomputed);

    if (!std.mem.eql(u8, sig_b64, recomputed_b64)) return JwtError.InvalidSignature;

    var payload_json_buf: [512]u8 = undefined;
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload_b64) catch return JwtError.InvalidFormat;
    std.base64.url_safe_no_pad.Decoder.decode(&payload_json_buf, payload_b64) catch return JwtError.InvalidFormat;

    var parsed = try std.json.parseFromSlice(Claims, alloc, payload_json_buf[0..decoded_len], .{});
    defer parsed.deinit();

    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    if (parsed.value.exp <= tv.sec) return JwtError.Expired;

    return Claims{
        .sub = parsed.value.sub,
        .email = try alloc.dupe(u8, parsed.value.email),
        .exp = parsed.value.exp,
    };
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
        }

        const cookie_header = req.headers.get("Cookie") orelse
            return Response.redirect(alloc, self.config.redirect_to);

        const token = cookieGet(cookie_header) orelse
            return Response.redirect(alloc, self.config.redirect_to);

        const claims = jwtVerify(alloc, token, self.config.secret) catch
            return Response.redirect(alloc, self.config.redirect_to);

        const user_id = try std.fmt.allocPrint(alloc, "{d}", .{claims.sub});
        const email = try alloc.dupe(u8, claims.email);
        alloc.free(claims.email);

        try req.params.put(alloc, try alloc.dupe(u8, "_user_id"), user_id);
        try req.params.put(alloc, try alloc.dupe(u8, "_user_email"), email);

        return next(alloc, req);
    }
};
