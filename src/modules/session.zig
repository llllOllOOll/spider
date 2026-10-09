//! Login sessions for an app with its own users: a signed cookie.
//!
//! ```zig
//! // after checking the password
//! return c.redirectWith("/", try spider.session.start(c, .{
//!     .id = user_id, .email = user.email, .name = user.name,
//! }));
//!
//! // main.zig
//! server.use(spider.session.middleware())
//!
//! // logging out
//! return c.redirectWith("/", try spider.session.end(c));
//! ```
//!
//! The cookie holds a token signed with the app's secret (HS256), so the
//! server keeps no table of sessions: it trusts what it signed. The
//! middleware reads it on every request and fills in the request's user,
//! which is what `.authenticated` and `.roles` on a route check, and what
//! `c.userId()` returns. A route that is not `.public` answers 401 to a
//! request with no session (error.Unauthorized: an app's error handler
//! turns that into a redirect to the login page).
//!
//! An API sends the same token in `Authorization: Bearer <token>`; get it
//! with `spider.session.token(c, user)`.
//!
//! The secret is JWT_SECRET, from the environment or .env (`spider new`
//! writes a random one). A session cannot be taken back before it expires:
//! there is nothing on the server to delete. Changing the secret ends all
//! of them.
const std = @import("std");
const builtin = @import("builtin");
const ctx_mod = @import("../core/context.zig");
const Ctx = ctx_mod.Ctx;
const NextFn = ctx_mod.NextFn;
const Response = ctx_mod.Response;
const MiddlewareFn = ctx_mod.MiddlewareFn;
const ResponseOptions = ctx_mod.ResponseOptions;
const jwt = @import("auth/auth.zig");
const env = @import("../internal/env.zig");
const auth_marker = @import("auth_marker.zig");

/// Who is logged in.
pub const User = struct {
    id: []const u8,
    email: []const u8 = "",
    name: []const u8 = "",
    roles: []const []const u8 = &.{},
};

/// The settings of the session cookie and its token. Change them through
/// `spider.session.options` before the server starts.
pub const Options = struct {
    /// What tokens are signed with. Null: JWT_SECRET from the environment
    /// or .env.
    secret: ?[]const u8 = null,
    /// Name of the cookie that carries the token.
    cookie: []const u8 = "session",
    /// How long a login lasts, in seconds. Default: 14 days.
    max_age: u32 = 14 * 24 * 60 * 60,
    /// The cookie's Secure attribute. Browsers still send a Secure cookie
    /// to http://localhost; turn it off to test from another machine over
    /// plain http.
    secure: bool = true,
};

/// Set before the server starts to change the defaults.
pub var options: Options = .{};

/// The placeholder `.env.example` carries: not a secret.
const placeholder = "change_me_in_production";

/// What `start`, `token` and the middleware fail with when there is no secret.
pub const Error = error{
    /// No JWT_SECRET (or it is still the placeholder) in a release build.
    SessionSecretMissing,
};

/// Response options that log `user` in: a Set-Cookie with the signed token.
pub fn start(c: *Ctx, user: User) !ResponseOptions {
    return c.withCookie(options.cookie, try token(c, user), .{
        .max_age = options.max_age,
        .secure = options.secure,
    });
}

/// The signed token alone, for an API whose clients send it back in
/// `Authorization: Bearer <token>`.
pub fn token(c: *Ctx, user: User) ![]const u8 {
    return sign(c.arena, try secret(c._io), user, nowSeconds(c._io) + options.max_age);
}

/// Response options that log the user out: the cookie, emptied and expired.
pub fn end(c: *Ctx) !ResponseOptions {
    const cleared = try c.deleteCookie(options.cookie, .{ .secure = options.secure });
    const headers = try c.arena.alloc([2][]const u8, 1);
    headers[0] = .{ "Set-Cookie", cleared };
    return .{ .headers = headers };
}

/// The middleware: `server.use(spider.session.middleware())`.
pub fn middleware() MiddlewareFn {
    auth_marker.mark(run);
    return run;
}

fn run(c: *Ctx, next: NextFn) anyerror!Response {
    if (presented(c)) |sent| {
        // A token that does not verify is the same as none.
        if (verify(c.arena, c._io, try secret(c._io), sent)) |user| {
            try c.setUser(.{
                .id = user.id,
                .email = if (user.email.len > 0) user.email else null,
                .name = if (user.name.len > 0) user.name else null,
            });
            try c.setRoles(user.roles);
        } else |_| {}
    }
    // An address that is no route gets its 404 whoever asks.
    if (c.userId() == null and c.hasRoute() and !c.route().public) return error.Unauthorized;
    return next(c);
}

/// The token the request carries: the Authorization header first, then the
/// cookie.
fn presented(c: *Ctx) ?[]const u8 {
    if (c.header("Authorization")) |value| {
        const scheme = "Bearer ";
        if (value.len > scheme.len and std.ascii.eqlIgnoreCase(value[0..scheme.len], scheme)) {
            return std.mem.trim(u8, value[scheme.len..], " ");
        }
    }
    return c.cookie(options.cookie);
}

const Claims = struct {
    sub: []const u8,
    email: []const u8 = "",
    name: []const u8 = "",
    roles: []const []const u8 = &.{},
    exp: i64,
};

fn sign(arena: std.mem.Allocator, key: []const u8, user: User, expires: i64) ![]const u8 {
    return jwt.jwtSign(arena, Claims{
        .sub = user.id,
        .email = user.email,
        .name = user.name,
        .roles = user.roles,
        .exp = expires,
    }, key);
}

/// The user a token names, when it was signed with `key` and has not
/// expired. Everything it returns lives in `arena`.
fn verify(arena: std.mem.Allocator, io: std.Io, key: []const u8, sent: []const u8) !User {
    const payload = try jwt.jwtPayload(arena, sent, key);
    const claims = std.json.parseFromSliceLeaky(Claims, arena, payload, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return jwt.JwtError.InvalidFormat,
    };
    if (claims.sub.len == 0) return jwt.JwtError.InvalidFormat;
    if (claims.exp <= nowSeconds(io)) return jwt.JwtError.Expired;
    return .{ .id = claims.sub, .email = claims.email, .name = claims.name, .roles = claims.roles };
}

fn nowSeconds(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}

// ── the secret ──────────────────────────────────────────────────────────

var resolved: ?[]const u8 = null;
var resolving: std.atomic.Mutex = .unlocked;
var throwaway: [43]u8 = undefined;

/// The signing secret: `options.secret`, else JWT_SECRET. Without one, a
/// debug build makes one up for this run (logins end when the app
/// restarts) and says so; a release build refuses.
fn secret(io: std.Io) Error![]const u8 {
    if (options.secret) |configured| return configured;

    while (!resolving.tryLock()) std.atomic.spinLoopHint();
    defer resolving.unlock();
    if (resolved) |known| return known;

    if (env.get("JWT_SECRET")) |from_env| {
        if (from_env.len > 0 and !std.mem.eql(u8, from_env, placeholder)) {
            resolved = from_env;
            return from_env;
        }
    }
    if (builtin.mode != .debug) {
        std.log.err("spider.session: JWT_SECRET is not set (or is still \"{s}\"). Set it to a long random value.", .{placeholder});
        return error.SessionSecretMissing;
    }
    var random: [32]u8 = undefined;
    io.random(&random);
    resolved = std.base64.url_safe_no_pad.Encoder.encode(&throwaway, &random);
    if (!builtin.is_test) {
        std.log.warn("spider.session: no JWT_SECRET; using a random one for this run, so logins end when the app restarts. Set JWT_SECRET in .env to keep them.", .{});
    }
    return resolved.?;
}

// ── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "a token names its user, to whoever has the secret" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const far = nowSeconds(t.io) + 3600;

    const signed = try sign(a, "k1", .{ .id = "42", .email = "ana@example.com", .name = "Ana \"A\" Ribeiro", .roles = &.{ "admin", "editor" } }, far);
    const user = try verify(a, t.io, "k1", signed);
    try t.expectEqualStrings("42", user.id);
    try t.expectEqualStrings("ana@example.com", user.email);
    try t.expectEqualStrings("Ana \"A\" Ribeiro", user.name);
    try t.expectEqual(@as(usize, 2), user.roles.len);
    try t.expectEqualStrings("editor", user.roles[1]);

    try t.expectError(jwt.JwtError.InvalidSignature, verify(a, t.io, "k2", signed));
}

test "an expired token, a forged one and garbage are refused" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now = nowSeconds(t.io);

    const expired = try sign(a, "k", .{ .id = "1" }, now - 1);
    try t.expectError(jwt.JwtError.Expired, verify(a, t.io, "k", expired));
    const just_now = try sign(a, "k", .{ .id = "1" }, now);
    try t.expectError(jwt.JwtError.Expired, verify(a, t.io, "k", just_now));

    // Someone edits the payload to become user 1 and keeps the signature.
    const mine = try sign(a, "k", .{ .id = "2" }, now + 60);
    const theirs = try sign(a, "another key", .{ .id = "1" }, now + 60);
    var mine_parts = std.mem.splitScalar(u8, mine, '.');
    var theirs_parts = std.mem.splitScalar(u8, theirs, '.');
    const header = mine_parts.next().?;
    _ = mine_parts.next();
    _ = theirs_parts.next();
    const forged = try std.fmt.allocPrint(a, "{s}.{s}.{s}", .{ header, theirs_parts.next().?, mine_parts.next().? });
    try t.expectError(jwt.JwtError.InvalidSignature, verify(a, t.io, "k", forged));

    try t.expectError(jwt.JwtError.InvalidFormat, verify(a, t.io, "k", "garbage"));
    try t.expectError(jwt.JwtError.InvalidFormat, verify(a, t.io, "k", ""));

    // Signed by us, but not a session: no subject.
    const no_subject = try jwt.jwtSign(a, .{ .sub = "", .exp = now + 60 }, "k");
    try t.expectError(jwt.JwtError.InvalidFormat, verify(a, t.io, "k", no_subject));
    const other_shape = try jwt.jwtSign(a, .{ .user = 7 }, "k");
    try t.expectError(jwt.JwtError.InvalidFormat, verify(a, t.io, "k", other_shape));
}
