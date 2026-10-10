// End-to-end tests for spider.clerk against a fake Clerk: the key set it
// downloads when it starts and again when a token names an unknown key,
// and the callback that turns an authorization code into the session cookie.

const std = @import("std");
const spider = @import("spider");
const h = @import("../e2e_test.zig");

var clerk: spider.clerk.Clerk = undefined;
var idp_port: u16 = 0;
var app_port: u16 = 0;
var started = false;
var start_mutex: std.Io.Mutex = .init;

var jwks_calls: std.atomic.Value(u32) = .init(0);
var token_calls: std.atomic.Value(u32) = .init(0);

// A debug allocator on purpose: it overwrites memory when it is freed, so
// a URL that Clerk freed and kept using does not look valid by accident.
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

// ── fake Clerk ──────────────────────────────────────────────────────────

fn idpKeys(c: *spider.Ctx) !spider.Response {
    _ = jwks_calls.fetchAdd(1, .seq_cst);
    return c.json(.{ .keys = &.{.{ .kid = "k1", .kty = "RSA", .n = "AQAB", .e = "AQAB" }} }, .{});
}

fn idpToken(c: *spider.Ctx) !spider.Response {
    _ = token_calls.fetchAdd(1, .seq_cst);
    return c.json(.{ .id_token = "header.payload.signature" }, .{});
}

fn runIdp(port: u16) void {
    var s = spider.app(.{});
    s
        .get("/.well-known/jwks.json", idpKeys, .{})
        .post("/oauth/token", idpToken, .{})
        .listen(.{ .port = port, .host = "127.0.0.1" }) catch |err| {
        std.log.err("fake clerk listen() failed: {s}", .{@errorName(err)});
    };
}

// ── app under test ──────────────────────────────────────────────────────

fn runApp(port: u16) void {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    const io = threaded.io();
    const alc = debug_allocator.allocator();

    // A publishable key is "pk_test_" + base64 of where the instance lives.
    var issuer_buf: [64]u8 = undefined;
    const issuer_json = std.fmt.bufPrint(&issuer_buf, "{{\"issuer\":\"http://127.0.0.1:{d}\"}}", .{idp_port}) catch unreachable;
    var key_buf: [160]u8 = undefined;
    const encoded = std.base64.url_safe_no_pad.Encoder.encode(key_buf[8..], issuer_json);
    @memcpy(key_buf[0..8], "pk_test_");
    const publishable_key = std.heap.smp_allocator.dupe(u8, key_buf[0 .. 8 + encoded.len]) catch unreachable;

    clerk = spider.clerk.Clerk.init(alc, io, .{
        .publishable_key = publishable_key,
        .secret_key = "sk_test_secret",
        .redirect_uri = "http://127.0.0.1/auth/callback",
        .after_callback_path = "/home",
    }) catch |err| {
        std.log.err("Clerk.init failed: {s}", .{@errorName(err)});
        return;
    };

    var s = spider.app(.{});
    s
        .get("/login", clerk.loginHandler(), .{ .public = true })
        .get("/auth/callback", clerk.callbackHandler(), .{ .public = true })
        .listen(.{ .port = port, .host = "127.0.0.1" }) catch |err| {
        std.log.err("clerk app listen() failed: {s}", .{@errorName(err)});
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

test "clerk: the key set can be downloaded again after init (a token with a new key id)" {
    try ensureStarted(std.testing.io);
    try std.testing.expectEqual(@as(u32, 1), jwks_calls.load(.seq_cst));

    // What the middleware does when a token names a key it has not seen.
    try clerk.jwks.fetchJwks();
    try std.testing.expectEqual(@as(u32, 2), jwks_calls.load(.seq_cst));
}

/// The value of `name` in a query string or in a Set-Cookie line.
fn valueOf(text: []const u8, name: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, name)) |i| : (at = i + 1) {
        const before_ok = i == 0 or text[i - 1] == '?' or text[i - 1] == '&' or text[i - 1] == ' ';
        const eq = i + name.len;
        if (!before_ok or eq >= text.len or text[eq] != '=') continue;
        const end = std.mem.indexOfAnyPos(u8, text, eq + 1, "&;") orelse text.len;
        return text[eq + 1 .. end];
    }
    return null;
}

/// Every Set-Cookie line of a response whose cookie is `name`.
fn setCookieLine(res: h.HttpResponse, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, res.head, "\r\n");
    while (it.next()) |line| {
        if (!std.ascii.startsWithIgnoreCase(line, "set-cookie:")) continue;
        const value = std.mem.trim(u8, line["set-cookie:".len..], " ");
        if (std.mem.startsWith(u8, value, name) and value.len > name.len and value[name.len] == '=') return value;
    }
    return null;
}

const state_cookie = "__clerk_oauth_state";

test "clerk login: redirects to Clerk with a state that is also a cookie of this browser" {
    try ensureStarted(std.testing.io);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const res = try h.request(std.testing.io, a, app_port, "/login", .{});
    try std.testing.expectEqual(@as(u16, 302), res.status);
    const location = res.header("Location").?;
    try std.testing.expect(std.mem.indexOf(u8, location, "/oauth/authorize?response_type=code&client_id=pk_test_") != null);
    // The redirect address is one value of the URL.
    try std.testing.expectEqualStrings("http%3A//127.0.0.1/auth/callback", valueOf(location, "redirect_uri").?);

    const state = valueOf(location, "state").?;
    try std.testing.expect(state.len >= 32);
    const cookie = setCookieLine(res, state_cookie).?;
    try std.testing.expectEqualStrings(state, valueOf(cookie, state_cookie).?);
    try std.testing.expect(std.mem.indexOf(u8, cookie, "HttpOnly") != null);

    const again = try h.request(std.testing.io, a, app_port, "/login", .{});
    try std.testing.expect(!std.mem.eql(u8, state, valueOf(again.header("Location").?, "state").?));
}

test "clerk callback: with this browser's state, the code becomes the session cookie and a redirect" {
    try ensureStarted(std.testing.io);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const login = try h.request(std.testing.io, a, app_port, "/login", .{});
    const state = valueOf(login.header("Location").?, "state").?;
    const cookie_line = try std.fmt.allocPrint(a, "Cookie: {s}={s}", .{ state_cookie, state });

    const res = try h.request(std.testing.io, a, app_port, try std.fmt.allocPrint(a, "/auth/callback?code=abc&state={s}", .{state}), .{ .headers = &.{cookie_line} });
    try std.testing.expectEqual(@as(u16, 302), res.status);
    try std.testing.expectEqualStrings("/home", res.header("Location").?);
    const session = setCookieLine(res, "__session").?;
    try std.testing.expect(std.mem.startsWith(u8, session, "__session=header.payload.signature;"));
    // The state did its job: its cookie is removed.
    const cleared = setCookieLine(res, state_cookie).?;
    try std.testing.expect(std.mem.indexOf(u8, cleared, "Max-Age=0") != null);
}

test "clerk callback: a state that is not this browser's goes back to the login, and Clerk is not asked" {
    try ensureStarted(std.testing.io);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const login = try h.request(std.testing.io, a, app_port, "/login", .{});
    const state = valueOf(login.header("Location").?, "state").?;
    const cookie_line = try std.fmt.allocPrint(a, "Cookie: {s}={s}", .{ state_cookie, state });
    const before = token_calls.load(.seq_cst);

    // No cookie: a link someone else made. No state. Another state.
    const targets = [_]struct { target: []const u8, headers: []const []const u8 }{
        .{ .target = try std.fmt.allocPrint(a, "/auth/callback?code=abc&state={s}", .{state}), .headers = &.{} },
        .{ .target = "/auth/callback?code=abc", .headers = &.{cookie_line} },
        .{ .target = "/auth/callback?code=abc&state=0000000000000000000000000000000f", .headers = &.{cookie_line} },
    };
    for (targets) |t| {
        const res = try h.request(std.testing.io, a, app_port, t.target, .{ .headers = t.headers });
        try std.testing.expectEqual(@as(u16, 302), res.status);
        try std.testing.expectEqualStrings("/login", res.header("Location").?);
        try std.testing.expect(setCookieLine(res, "__session") == null);
    }
    try std.testing.expectEqual(before, token_calls.load(.seq_cst));
}

test "clerk callback: without a code it is a 400" {
    try ensureStarted(std.testing.io);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const res = try h.request(std.testing.io, arena.allocator(), app_port, "/auth/callback", .{});
    try std.testing.expectEqual(@as(u16, 400), res.status);
}
