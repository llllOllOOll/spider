// End-to-end tests for the Keycloak provider (login, callback, refresh,
// JWKS middleware) against a fake Keycloak running in-process.
//
// The fake IdP serves a real JWKS and a token endpoint; JWTs are genuinely
// RS256-signed at test time with the test-only key at the bottom of this
// file, so the middleware's signature/issuer/exp checks run for real.

const std = @import("std");
const spider = @import("spider");
const h = @import("../e2e_test.zig");

const realm = "test";

var idp_port: u16 = 0;
var app_port: u16 = 0;
var token_calls = std.atomic.Value(u32).init(0);
var certs_calls = std.atomic.Value(u32).init(0);
/// When true the fake IdP also publishes the key under kid "k2" (rotation).
var serve_k2 = std.atomic.Value(bool).init(false);
var kc: spider.keycloak.Keycloak = undefined;
var start_mutex: std.Io.Mutex = .init;
var started = false;

// ── RS256 signing (test only) ───────────────────────────────────────────

const Modulus = std.crypto.ff.Modulus(2048);

fn hexToBytes(comptime hex: []const u8) [256]u8 {
    @setEvalBranchQuota(100_000);
    var clean: [512]u8 = undefined;
    var n: usize = 0;
    for (hex) |ch| {
        if (ch == '\n') continue;
        clean[n] = ch;
        n += 1;
    }
    var out: [256]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, clean[0..n]) catch unreachable;
    return out;
}

const n_bytes = hexToBytes(n_hex);
const d_bytes = hexToBytes(d_hex);

/// PKCS#1 v1.5 / SHA-256 signature: EM^d mod n.
fn signRs256(msg: []const u8) ![256]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(msg, &digest, .{});
    const digest_info_prefix = [_]u8{ 0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20 };

    var em: [256]u8 = undefined;
    const t_len = digest_info_prefix.len + digest.len;
    em[0] = 0x00;
    em[1] = 0x01;
    @memset(em[2 .. 256 - t_len - 1], 0xff);
    em[256 - t_len - 1] = 0x00;
    @memcpy(em[256 - t_len ..][0..digest_info_prefix.len], &digest_info_prefix);
    @memcpy(em[256 - digest.len ..], &digest);

    const n = try Modulus.fromBytes(&n_bytes, .big);
    const m = try Modulus.Fe.fromBytes(n, &em, .big);
    const s = try n.powWithEncodedExponent(m, &d_bytes, .big);
    var out: [256]u8 = undefined;
    try s.toBytes(&out, .big);
    return out;
}

const b64 = std.base64.url_safe_no_pad;

fn issuer(alc: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(alc, "http://127.0.0.1:{d}/realms/{s}", .{ idp_port, realm });
}

/// Builds a signed JWT issued to this app's client (like a real Keycloak
/// access token: `aud` "account", `azp` the client). `extra_json` is spliced
/// into the payload object (e.g. `,"organizations":{...}`).
fn makeJwt(alc: std.mem.Allocator, exp: i64, extra_json: []const u8) ![]const u8 {
    return makeJwtKid(alc, "k1", exp, extra_json);
}

const own_client = ",\"aud\":\"account\",\"azp\":\"spider-app\"";

fn makeJwtKid(alc: std.mem.Allocator, kid: []const u8, exp: i64, extra_json: []const u8) ![]const u8 {
    return makeJwtFull(alc, kid, exp, try std.fmt.allocPrint(alc, "{s}{s}", .{ own_client, extra_json }));
}

/// Like makeJwtKid, without the default aud/azp: `claims_json` says who the
/// token was issued to.
fn makeJwtFull(alc: std.mem.Allocator, kid: []const u8, exp: i64, claims_json: []const u8) ![]const u8 {
    const header = try std.fmt.allocPrint(alc, "{{\"alg\":\"RS256\",\"typ\":\"JWT\",\"kid\":\"{s}\"}}", .{kid});
    const payload = try std.fmt.allocPrint(alc, "{{\"sub\":\"user-1\",\"email\":\"u@test\",\"iss\":\"{s}\",\"exp\":{d}{s}}}", .{ try issuer(alc), exp, claims_json });

    const h_enc = try alc.alloc(u8, b64.Encoder.calcSize(header.len));
    _ = b64.Encoder.encode(h_enc, header);
    const p_enc = try alc.alloc(u8, b64.Encoder.calcSize(payload.len));
    _ = b64.Encoder.encode(p_enc, payload);

    const signing_input = try std.fmt.allocPrint(alc, "{s}.{s}", .{ h_enc, p_enc });
    const sig = try signRs256(signing_input);
    const s_enc = try alc.alloc(u8, b64.Encoder.calcSize(sig.len));
    _ = b64.Encoder.encode(s_enc, &sig);
    return std.fmt.allocPrint(alc, "{s}.{s}", .{ signing_input, s_enc });
}

const far_future: i64 = 4102444800; // 2100-01-01

const orgs_claim = ",\"organizations\":{\"orgA\":{\"name\":\"A\",\"roles\":[\"admin\"]},\"orgB\":{\"name\":\"B\",\"roles\":[\"resident\"]}}";

// ── fake Keycloak ───────────────────────────────────────────────────────

fn idpCerts(c: *spider.Ctx) !spider.Response {
    _ = certs_calls.fetchAdd(1, .seq_cst);
    var n_enc: [b64.Encoder.calcSize(256)]u8 = undefined;
    _ = b64.Encoder.encode(&n_enc, &n_bytes);
    const Key = struct { kid: []const u8, kty: []const u8, n: []const u8, e: []const u8 };
    const k1: Key = .{ .kid = "k1", .kty = "RSA", .n = &n_enc, .e = "AQAB" };
    const k2: Key = .{ .kid = "k2", .kty = "RSA", .n = &n_enc, .e = "AQAB" };
    if (serve_k2.load(.seq_cst)) return c.json(.{ .keys = &[_]Key{ k1, k2 } }, .{});
    return c.json(.{ .keys = &[_]Key{k1} }, .{});
}

fn idpToken(c: *spider.Ctx) !spider.Response {
    _ = token_calls.fetchAdd(1, .seq_cst);
    const jwt = try makeJwt(c.arena, far_future, "");
    return c.json(.{ .access_token = jwt, .id_token = jwt, .refresh_token = "refresh-2" }, .{});
}

fn runIdp(port: u16) void {
    var s = spider.app(.{});
    s
        .get("/realms/" ++ realm ++ "/protocol/openid-connect/certs", idpCerts, .{})
        .post("/realms/" ++ realm ++ "/protocol/openid-connect/token", idpToken, .{})
        .listen(.{ .port = port, .host = "127.0.0.1" }) catch |err| {
        std.log.err("fake idp listen() failed: {s}", .{@errorName(err)});
    };
}

// ── app under test ──────────────────────────────────────────────────────

fn ok(c: *spider.Ctx) !spider.Response {
    return c.text("ok", .{});
}

fn register(c: *spider.Ctx) !spider.Response {
    return kc.authorize(c, .{ .endpoint = .registrations, .payload = "invite:tok en/1", .idp_hint = "google" });
}

fn errorHandler(c: *spider.Ctx, err: anyerror) !spider.Response {
    return switch (err) {
        error.Forbidden => c.text("forbidden", .{ .status = .forbidden }),
        else => c.text(@errorName(err), .{ .status = spider.statusForError(err) }),
    };
}

fn runApp(port: u16) void {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    const io = threaded.io();
    const alc = std.heap.smp_allocator;

    kc = spider.keycloak.Keycloak.init(alc, io, .{
        .base_url = std.fmt.allocPrint(alc, "http://127.0.0.1:{d}", .{idp_port}) catch unreachable,
        .realm = realm,
        .client_id = "spider-app",
        .client_secret = "secret",
        .redirect_uri = std.fmt.allocPrint(alc, "http://127.0.0.1:{d}/auth/callback", .{port}) catch unreachable,
        .login_path = "/auth/login",
        .after_callback_path = "/home",
        .auth_skip_paths = &.{ "/auth/login", "/auth/callback", "/auth/refresh", "/auth/register" },
        .active_org_cookie = "active_org",
    }) catch |err| {
        std.log.err("Keycloak.init failed: {s}", .{@errorName(err)});
        return;
    };

    var s = spider.app(.{});
    s
        .use(kc.middleware())
        .get("/auth/login", kc.loginHandler(), .{})
        .get("/auth/callback", kc.callbackHandler(), .{})
        .get("/auth/refresh", kc.refreshHandler(), .{})
        .get("/auth/register", register, .{})
        .get("/home", ok, .{})
        .get("/tickets", ok, .{})
        .get("/org/:id", ok, .{ .org_roles = &.{"admin"} })
        // Not in auth_skip_paths: public only because the route says so.
        .get("/open/:id", ok, .{ .public = true })
        .onError(errorHandler)
        .listen(.{ .port = port, .host = "127.0.0.1" }) catch |err| {
        std.log.err("keycloak app listen() failed: {s}", .{@errorName(err)});
    };
}

fn ensureStarted(io: std.Io) !void {
    try start_mutex.lock(io);
    defer start_mutex.unlock(io);
    if (started) return;

    idp_port = try h.reserveEphemeralPort(io);
    (try std.Thread.spawn(.{}, runIdp, .{idp_port})).detach();
    try h.waitForPort(io, idp_port);

    app_port = try h.reserveEphemeralPort(io);
    (try std.Thread.spawn(.{}, runApp, .{app_port})).detach();
    try h.waitForPort(io, app_port);
    started = true;
}

const Env = struct {
    threaded: std.Io.Threaded,
    arena: std.heap.ArenaAllocator,

    fn init() !Env {
        var e: Env = .{ .threaded = .init(std.testing.allocator, .{}), .arena = .init(std.testing.allocator) };
        try ensureStarted(e.threaded.io());
        return e;
    }
    fn deinit(self: *Env) void {
        self.arena.deinit();
        self.threaded.deinit();
    }
    fn get(self: *Env, target: []const u8, headers: []const []const u8) !h.HttpResponse {
        return h.request(self.threaded.io(), self.arena.allocator(), app_port, target, .{ .headers = headers });
    }
    fn alc(self: *Env) std.mem.Allocator {
        return self.arena.allocator();
    }
};

/// Value of the first `Set-Cookie: name=...` (without attributes).
fn setCookieValue(res: h.HttpResponse, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, res.head, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "set-cookie")) continue;
        const v = std.mem.trim(u8, line[colon + 1 ..], " ");
        if (v.len > name.len and std.mem.startsWith(u8, v, name) and v[name.len] == '=') {
            const rest = v[name.len + 1 ..];
            return rest[0 .. std.mem.indexOfScalar(u8, rest, ';') orelse rest.len];
        }
    }
    return null;
}

fn queryParam(target: []const u8, name: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

// ── login / callback: OAuth state ───────────────────────────────────────

test "keycloak login: redirects with a state whose nonce is also set as cookie" {
    var e = try Env.init();
    defer e.deinit();
    const res = try e.get("/auth/login", &.{});
    try std.testing.expectEqual(@as(u16, 302), res.status);

    const loc = res.header("Location").?;
    try std.testing.expect(std.mem.indexOf(u8, loc, "/realms/test/protocol/openid-connect/auth?") != null);
    const state = queryParam(loc, "state").?;
    const cookie = setCookieValue(res, "__oauth_state").?;
    try std.testing.expectEqual(@as(usize, 32), cookie.len);
    try std.testing.expectEqualStrings(cookie, state);
    // redirect_uri is percent-encoded as one value
    try std.testing.expect(std.mem.startsWith(u8, queryParam(loc, "redirect_uri").?, "http%3A//127.0.0.1%3A"));
}

test "keycloak login: every login gets a fresh nonce" {
    var e = try Env.init();
    defer e.deinit();
    const a = try e.get("/auth/login", &.{});
    const b = try e.get("/auth/login", &.{});
    try std.testing.expect(!std.mem.eql(u8, setCookieValue(a, "__oauth_state").?, setCookieValue(b, "__oauth_state").?));
}

test "keycloak callback: missing state cookie is rejected before the token exchange" {
    var e = try Env.init();
    defer e.deinit();
    const before = token_calls.load(.seq_cst);
    const res = try e.get("/auth/callback?code=abc&state=0123456789abcdef0123456789abcdef", &.{});
    try std.testing.expectEqual(@as(u16, 302), res.status);
    try std.testing.expectEqualStrings("/auth/login", res.header("Location").?);
    try std.testing.expect(setCookieValue(res, "__session") == null);
    try std.testing.expectEqual(before, token_calls.load(.seq_cst));
}

test "keycloak callback: state not matching the cookie is rejected" {
    var e = try Env.init();
    defer e.deinit();
    const before = token_calls.load(.seq_cst);
    const res = try e.get("/auth/callback?code=abc&state=ffffffffffffffffffffffffffffffff", &.{"Cookie: __oauth_state=0123456789abcdef0123456789abcdef"});
    try std.testing.expectEqualStrings("/auth/login", res.header("Location").?);
    try std.testing.expect(setCookieValue(res, "__session") == null);
    try std.testing.expectEqual(before, token_calls.load(.seq_cst));
}

test "keycloak callback: missing or malformed state is rejected" {
    var e = try Env.init();
    defer e.deinit();
    const cookie = "Cookie: __oauth_state=0123456789abcdef0123456789abcdef";
    for ([_][]const u8{
        "/auth/callback?code=abc",
        "/auth/callback?code=abc&state=",
        "/auth/callback?code=abc&state=short",
        "/auth/callback?code=abc&state=0123456789abcdef0123456789abcdefXinvite:x",
        "/auth/callback?code=abc&state=%zz",
    }) |target| {
        const res = try e.get(target, &.{cookie});
        try std.testing.expectEqualStrings("/auth/login", res.header("Location").?);
        try std.testing.expect(setCookieValue(res, "__session") == null);
    }
}

test "keycloak callback: real round-trip logs in and clears the state cookie" {
    var e = try Env.init();
    defer e.deinit();
    const login = try e.get("/auth/login", &.{});
    const state = queryParam(login.header("Location").?, "state").?;
    const nonce = setCookieValue(login, "__oauth_state").?;

    const before = token_calls.load(.seq_cst);
    const target = try std.fmt.allocPrint(e.alc(), "/auth/callback?code=abc&state={s}", .{state});
    const cookie = try std.fmt.allocPrint(e.alc(), "Cookie: __oauth_state={s}", .{nonce});
    const res = try e.get(target, &.{cookie});

    try std.testing.expectEqual(@as(u16, 302), res.status);
    try std.testing.expectEqualStrings("/home", res.header("Location").?);
    try std.testing.expect(setCookieValue(res, "__session").?.len > 0);
    try std.testing.expectEqualStrings("refresh-2", setCookieValue(res, "__refresh").?);
    try std.testing.expectEqualStrings("", setCookieValue(res, "__oauth_state").?);
    try std.testing.expectEqual(before + 1, token_calls.load(.seq_cst));

    // The session it set is accepted by the JWKS middleware.
    const session = try std.fmt.allocPrint(e.alc(), "Cookie: __session={s}", .{setCookieValue(res, "__session").?});
    const home = try e.get("/tickets", &.{session});
    try std.testing.expectEqual(@as(u16, 200), home.status);
}

test "keycloak authorize(): registration + idp hint + invite payload round-trip" {
    var e = try Env.init();
    defer e.deinit();
    const start = try e.get("/auth/register", &.{});
    const loc = start.header("Location").?;
    try std.testing.expect(std.mem.indexOf(u8, loc, "/protocol/openid-connect/registrations?") != null);
    try std.testing.expectEqualStrings("google", queryParam(loc, "kc_idp_hint").?);

    const state = queryParam(loc, "state").?;
    const nonce = setCookieValue(start, "__oauth_state").?;
    const target = try std.fmt.allocPrint(e.alc(), "/auth/callback?code=abc&state={s}", .{state});
    const cookie = try std.fmt.allocPrint(e.alc(), "Cookie: __oauth_state={s}", .{nonce});
    const res = try e.get(target, &.{cookie});
    // Invite token is forwarded percent-encoded, never raw into Location.
    try std.testing.expectEqualStrings("/home?invite=tok%20en/1", res.header("Location").?);
}

// ── refresh: open redirect ──────────────────────────────────────────────

fn refreshLocation(e: *Env, next_raw: []const u8) ![]const u8 {
    const target = try std.fmt.allocPrint(e.alc(), "/auth/refresh?next={s}", .{next_raw});
    const res = try e.get(target, &.{"Cookie: __refresh=refresh-1"});
    try std.testing.expectEqual(@as(u16, 302), res.status);
    return res.header("Location").?;
}

test "keycloak refresh: external or tricky next falls back to after_callback_path" {
    var e = try Env.init();
    defer e.deinit();
    for ([_][]const u8{
        "https://evil.com",
        "https%3A%2F%2Fevil.com",
        "//evil.com",
        "%2F%2Fevil.com",
        "/%5Cevil.com",
        "%2F%5Cevil.com",
        "%2F%09%2Fevil.com",
        "%2F%0D%0ASet-Cookie:%20x=1",
        "evil.com",
        "%zz",
    }) |bad| {
        const loc = try refreshLocation(&e, bad);
        if (!std.mem.eql(u8, "/home", loc)) {
            std.debug.print("\nnext={s} redirected to {s}\n", .{ bad, loc });
            return error.TestUnexpectedResult;
        }
    }
}

test "keycloak refresh: local next with query string is honored" {
    var e = try Env.init();
    defer e.deinit();
    try std.testing.expectEqualStrings("/tickets?a=1&b=2", try refreshLocation(&e, "%2Ftickets%3Fa%3D1%26b%3D2"));
    try std.testing.expectEqualStrings("/dashboard", try refreshLocation(&e, "/dashboard"));
}

test "keycloak refresh: without next goes to after_callback_path" {
    var e = try Env.init();
    defer e.deinit();
    const res = try e.get("/auth/refresh", &.{"Cookie: __refresh=refresh-1"});
    try std.testing.expectEqualStrings("/home", res.header("Location").?);
}

// ── JWKS middleware ─────────────────────────────────────────────────────

test "jwks: expired session redirects to refresh keeping path AND query" {
    var e = try Env.init();
    defer e.deinit();
    const jwt = try makeJwt(e.alc(), 1000, "");
    const cookie = try std.fmt.allocPrint(e.alc(), "Cookie: __session={s}", .{jwt});
    const res = try e.get("/tickets?page=2&q=a%20b", &.{cookie});
    try std.testing.expectEqual(@as(u16, 302), res.status);
    const loc = res.header("Location").?;
    try std.testing.expectEqualStrings("/auth/refresh?next=/tickets%3Fpage%3D2%26q%3Da%2520b", loc);

    // ...and refresh sends the user back to exactly where they were.
    try std.testing.expectEqualStrings("/tickets?page=2&q=a%20b", try refreshLocation(&e, loc["/auth/refresh?next=".len..]));
}

test "jwks: valid token passes, bad signature and no token do not" {
    var e = try Env.init();
    defer e.deinit();
    const jwt = try makeJwt(e.alc(), far_future, "");
    const good = try std.fmt.allocPrint(e.alc(), "Cookie: __session={s}", .{jwt});
    try std.testing.expectEqual(@as(u16, 200), (try e.get("/tickets", &.{good})).status);

    const tampered = try e.alc().dupe(u8, jwt);
    tampered[tampered.len - 2] = if (tampered[tampered.len - 2] == 'A') 'B' else 'A';
    const bad = try std.fmt.allocPrint(e.alc(), "Cookie: __session={s}", .{tampered});
    try std.testing.expectEqual(@as(u16, 401), (try e.get("/tickets", &.{bad})).status);

    const none = try e.get("/tickets", &.{});
    try std.testing.expectEqual(@as(u16, 302), none.status);
    try std.testing.expectEqualStrings("/auth/login", none.header("Location").?);
}

test "jwks: a token issued to another client of the realm is rejected" {
    var e = try Env.init();
    defer e.deinit();
    const Case = struct { claims: []const u8, status: u16 };
    const cases = [_]Case{
        // Another client (e.g. admin-cli, a partner app) of the same realm.
        .{ .claims = ",\"aud\":\"account\",\"azp\":\"admin-cli\"", .status = 401 },
        // No client information at all.
        .{ .claims = "", .status = 401 },
        .{ .claims = ",\"aud\":[\"account\",\"other-api\"],\"azp\":\"other-app\"", .status = 401 },
        // Issued to this app, or to another client FOR this app (audience).
        .{ .claims = own_client, .status = 200 },
        .{ .claims = ",\"aud\":\"spider-app\",\"azp\":\"gateway\"", .status = 200 },
        .{ .claims = ",\"aud\":[\"account\",\"spider-app\"],\"azp\":\"gateway\"", .status = 200 },
    };
    for (cases) |c| {
        const jwt = try makeJwtFull(e.alc(), "k1", far_future, c.claims);
        const cookie = try std.fmt.allocPrint(e.alc(), "Cookie: __session={s}", .{jwt});
        const status = (try e.get("/tickets", &.{cookie})).status;
        if (status != c.status) std.debug.print("\nclaims {s}: expected {d}, got {d}\n", .{ c.claims, c.status, status });
        try std.testing.expectEqual(c.status, status);
    }
}

test "jwks + active_org_cookie: org_roles only count in the selected org" {
    var e = try Env.init();
    defer e.deinit();
    const jwt = try makeJwt(e.alc(), far_future, orgs_claim);
    const in_b = try std.fmt.allocPrint(e.alc(), "Cookie: __session={s}; active_org=orgB", .{jwt});
    const in_a = try std.fmt.allocPrint(e.alc(), "Cookie: __session={s}; active_org=orgA", .{jwt});
    const none = try std.fmt.allocPrint(e.alc(), "Cookie: __session={s}", .{jwt});
    const forged = try std.fmt.allocPrint(e.alc(), "Cookie: __session={s}; active_org=orgZ", .{jwt});

    try std.testing.expectEqual(@as(u16, 403), (try e.get("/org/1", &.{in_b})).status);
    try std.testing.expectEqual(@as(u16, 200), (try e.get("/org/1", &.{in_a})).status);
    try std.testing.expectEqual(@as(u16, 200), (try e.get("/org/1", &.{none})).status);
    // A cookie for an org the token doesn't list (stale after leaving it, or
    // forged) is ignored: same as no cookie, never a lock-out.
    try std.testing.expectEqual(@as(u16, 200), (try e.get("/org/1", &.{forged})).status);
}

test "jwks + active_org_cookie: stale cookie for a left org does not lock the user out" {
    var e = try Env.init();
    defer e.deinit();
    // Member of orgB only (resident). Cookie still says orgA (left it).
    const only_b = ",\"organizations\":{\"orgB\":{\"name\":\"B\",\"roles\":[\"admin\"]}}";
    const jwt = try makeJwt(e.alc(), far_future, only_b);
    const stale = try std.fmt.allocPrint(e.alc(), "Cookie: __session={s}; active_org=orgA", .{jwt});
    try std.testing.expectEqual(@as(u16, 200), (try e.get("/org/1", &.{stale})).status);
}

// ── JWKS key cache: concurrency, throttling, rotation ───────────────────

fn certsUrl(alc: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(alc, "http://127.0.0.1:{d}/realms/{s}/protocol/openid-connect/certs", .{ idp_port, realm });
}

const VerifyJob = struct {
    auth: *spider.jwks.JwksAuth,
    token: []const u8,
    ok: std.atomic.Value(u32) = .init(0),
    failed: std.atomic.Value(u32) = .init(0),
    rounds: usize = 1,
};

fn verifyWorker(job: *VerifyJob) void {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    for (0..job.rounds) |_| {
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        if (job.auth.verifyTokenIo(threaded.io(), arena.allocator(), job.token)) |_| {
            _ = job.ok.fetchAdd(1, .seq_cst);
        } else |_| {
            _ = job.failed.fetchAdd(1, .seq_cst);
        }
    }
}

fn runConcurrently(job: *VerifyJob, n: usize) !void {
    var threads: [32]std.Thread = undefined;
    for (threads[0..n]) |*t| t.* = try std.Thread.spawn(.{}, verifyWorker, .{job});
    for (threads[0..n]) |t| t.join();
}

test "jwks: burst of unknown-kid tokens triggers at most ONE JWKS fetch" {
    var e = try Env.init();
    defer e.deinit();
    var auth = try spider.jwks.JwksAuth.init(std.heap.smp_allocator, e.threaded.io(), .{
        .jwks_url = try certsUrl(e.alc()),
        .issuer = try issuer(e.alc()),
    });
    defer auth.deinit();

    const before = certs_calls.load(.seq_cst);
    var job: VerifyJob = .{ .auth = &auth, .token = try makeJwtKid(e.alc(), "unknown-kid", far_future, ""), .rounds = 5 };
    try runConcurrently(&job, 16);
    const fetches = certs_calls.load(.seq_cst) - before;
    if (fetches > 1) std.debug.print("\n  80 unknown-kid verifications caused {d} JWKS fetches\n", .{fetches});
    try std.testing.expect(fetches <= 1);
    try std.testing.expectEqual(@as(u32, 80), job.failed.load(.seq_cst));
}

test "jwks: key rotation is picked up with a single fetch while valid tokens keep verifying" {
    var e = try Env.init();
    defer e.deinit();
    serve_k2.store(false, .seq_cst);
    defer serve_k2.store(false, .seq_cst);
    var auth = try spider.jwks.JwksAuth.init(std.heap.smp_allocator, e.threaded.io(), .{
        .jwks_url = try certsUrl(e.alc()),
        .issuer = try issuer(e.alc()),
        .min_refetch_interval_ms = 0,
    });
    defer auth.deinit();

    serve_k2.store(true, .seq_cst); // IdP rotates: k2 now published
    const before = certs_calls.load(.seq_cst);

    // k1 tokens hammer the cache while k2 tokens force a refresh of it.
    var old_job: VerifyJob = .{ .auth = &auth, .token = try makeJwtKid(e.alc(), "k1", far_future, ""), .rounds = 20 };
    var new_job: VerifyJob = .{ .auth = &auth, .token = try makeJwtKid(e.alc(), "k2", far_future, ""), .rounds = 5 };
    var t_old: [8]std.Thread = undefined;
    for (&t_old) |*t| t.* = try std.Thread.spawn(.{}, verifyWorker, .{&old_job});
    try runConcurrently(&new_job, 8);
    for (t_old) |t| t.join();

    try std.testing.expectEqual(@as(u32, 160), old_job.ok.load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 40), new_job.ok.load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 1), certs_calls.load(.seq_cst) - before);
}

test "jwks: unknown kid refetch is throttled between bursts" {
    var e = try Env.init();
    defer e.deinit();
    var auth = try spider.jwks.JwksAuth.init(std.heap.smp_allocator, e.threaded.io(), .{
        .jwks_url = try certsUrl(e.alc()),
        .issuer = try issuer(e.alc()),
        .min_refetch_interval_ms = 60_000,
    });
    defer auth.deinit();

    const before = certs_calls.load(.seq_cst);
    const tok = try makeJwtKid(e.alc(), "nope", far_future, "");
    for (0..10) |_| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.UnknownKey, auth.verifyTokenIo(e.threaded.io(), arena.allocator(), tok));
    }
    // init() fetched moments ago, so nothing new inside the throttle window.
    try std.testing.expectEqual(@as(u32, 0), certs_calls.load(.seq_cst) - before);
}

// ── test-only RSA key (generated for these tests, never used anywhere else) ──

const n_hex =
    \\c5485079520c9d486ff95c883312da5df73235b4f716b6a3b0ce08047accbe5f
    \\93512c193791b02b041ec8321a4968e0254a2cb900cd3f9a6c0d170939ecfd4a
    \\68804fb1adeda666e8c0dfac3afcb46d0955baa671caa0fb08c514217defd27f
    \\eeb8649d2c9f4354c6a9ef03108b3765445149833b87f37a4fd9a119fdf53a06
    \\faf462751f6982feda84da9faebf7b46e9b2307c814bbdb3e970ffbb88d7e5d4
    \\429e0194f3dd9b5a7205e77bae99b1e274f2601fec886a0ead6af26adde39c6e
    \\e9c2b6819796d0c0cabc3e2b7e42003924c05687aec038a8f3047b5becc28448
    \\3efaf0a361e059486bb736cc3daa37639f900e7ce76f606da0c6520e63cd92ad
;
const d_hex =
    \\04e1f34bed61ee8a9a6adb856b6e2e056156d6c971cc181d19052061ac00613d
    \\d05193fbd3ca4147ef442bc441ae4b7030bc133b48efcb8130e76a088a6c7920
    \\5c51c0a72f1cd09f7f6736a1f69bc6836455c0d6d9be2019d66fba3dd1f61b89
    \\9b08e9449294268074a2440e195cb8b442ea981d2d5e0202a6f345ef74bf9afe
    \\021be7ca6e73de31ccb28a88dfeeff50c3a4edf2d7befb63983d5a363406bb1f
    \\50185c8458b0d11e5e5230058c690e8c768e634ed41d8c707de99005d9a371f2
    \\824e94ba354325e77c8b01a2e1cb81dc456b8ab8ab01297afc72aafd25560e0d
    \\ec44f2341eca31829a79e2f8aaa4cb6bb064c796e0329cea95d06c57726c43c1
;

test "jwks: a .public route needs no session, its neighbours still do" {
    var e = try Env.init();
    defer e.deinit();
    try std.testing.expectEqual(@as(u16, 200), (try e.get("/open/7", &.{})).status);
    const protected = try e.get("/tickets", &.{});
    try std.testing.expectEqual(@as(u16, 302), protected.status);
    try std.testing.expectEqualStrings("/auth/login", protected.header("Location").?);
    // A bad token doesn't matter on a public route either.
    try std.testing.expectEqual(@as(u16, 200), (try e.get("/open/7", &.{"Cookie: __session=garbage"})).status);
}

test "the built-in /up probe is public behind the auth middleware" {
    var e = try Env.init();
    defer e.deinit();
    try std.testing.expectEqual(@as(u16, 200), (try e.get("/up", &.{})).status);
}
