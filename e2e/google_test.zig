// End-to-end tests for spider.google against a fake Google: the login
// redirect with its state, and the callback that checks the state, trades
// the code for a token and reads the profile.

const std = @import("std");
const spider = @import("spider");
const h = @import("../e2e_test.zig");

var config: spider.google.GoogleConfig = undefined;
var idp_port: u16 = 0;
var app_port: u16 = 0;
var started = false;
var start_mutex: std.Io.Mutex = .init;

// ── fake Google ─────────────────────────────────────────────────────────

const TokenForm = struct {
    code: []const u8 = "",
    client_id: []const u8 = "",
    client_secret: []const u8 = "",
    redirect_uri: []const u8 = "",
    grant_type: []const u8 = "",
};

fn idpToken(c: *spider.Ctx) !spider.Response {
    const form = try c.parseForm(TokenForm);
    // What Google answers to a code it does not know.
    if (!std.mem.eql(u8, form.code, "good-code") or !std.mem.eql(u8, form.client_secret, "the-secret")) {
        return c.json(.{ .@"error" = "invalid_grant", .error_description = "Bad Request" }, .{ .status = .bad_request });
    }
    return c.json(.{ .access_token = "token-1", .token_type = "Bearer", .expires_in = 3599 }, .{});
}

fn idpUserinfo(c: *spider.Ctx) !spider.Response {
    const auth = c.header("Authorization") orelse "";
    if (!std.mem.eql(u8, auth, "Bearer token-1")) return c.json(.{ .@"error" = "invalid_token" }, .{ .status = .unauthorized });
    return c.json(.{
        .id = "1001",
        .email = "ana@example.com",
        .name = "Ana Ribeiro",
        .picture = "https://example.com/ana.png",
        .verified_email = true,
    }, .{});
}

fn runIdp(port: u16) void {
    var s = spider.app(.{});
    s
        .post("/token", idpToken, .{})
        .get("/userinfo", idpUserinfo, .{})
        .listen(.{ .port = port, .host = "127.0.0.1" }) catch |err| {
        std.log.err("fake google listen() failed: {s}", .{@errorName(err)});
    };
}

// ── app under test ──────────────────────────────────────────────────────

fn login(c: *spider.Ctx) !spider.Response {
    return spider.google.login(c, config);
}

fn callback(c: *spider.Ctx) !spider.Response {
    const profile = try spider.google.callback(c, config);
    // What a real callback does next: its own session, and the state
    // cookie out of the way.
    const cookies = try c.arena.alloc([2][]const u8, 1);
    cookies[0] = try spider.google.clearState(c, config);
    return c.text(try std.fmt.allocPrint(c.arena, "{s}|{s}|{s}|{s}", .{ profile.id, profile.email, profile.name, profile.picture }), .{ .cookies = cookies });
}

fn runApp(port: u16) void {
    const alc = std.heap.smp_allocator;
    config = .{
        .client_id = "client 1",
        .client_secret = "the-secret",
        .redirect_uri = std.fmt.allocPrint(alc, "http://127.0.0.1:{d}/auth/google/callback", .{port}) catch unreachable,
        .auth_endpoint = std.fmt.allocPrint(alc, "http://127.0.0.1:{d}/auth", .{idp_port}) catch unreachable,
        .token_endpoint = std.fmt.allocPrint(alc, "http://127.0.0.1:{d}/token", .{idp_port}) catch unreachable,
        .userinfo_endpoint = std.fmt.allocPrint(alc, "http://127.0.0.1:{d}/userinfo", .{idp_port}) catch unreachable,
    };
    var s = spider.app(.{});
    s
        .get("/auth/google", login, .{ .public = true })
        .get("/auth/google/callback", callback, .{ .public = true })
        .listen(.{ .port = port, .host = "127.0.0.1" }) catch |err| {
        std.log.err("google app listen() failed: {s}", .{@errorName(err)});
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

/// The value of `name` in a query string or in a Set-Cookie header.
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

const Started = struct { state: []const u8, cookie_line: []const u8 };

/// Starts a login and gives back the state it sent and the Cookie header
/// line a browser would send back.
fn startLogin(arena: std.mem.Allocator) !Started {
    const res = try h.request(std.testing.io, arena, app_port, "/auth/google", .{});
    try std.testing.expectEqual(@as(u16, 302), res.status);
    const location = res.header("Location").?;
    const state = valueOf(location, "state").?;
    const cookie = valueOf(res.header("Set-Cookie").?, spider.google.state_cookie).?;
    try std.testing.expectEqualStrings(state, cookie);
    return .{ .state = state, .cookie_line = try std.fmt.allocPrint(arena, "Cookie: {s}={s}", .{ spider.google.state_cookie, cookie }) };
}

test "google login: redirects to the consent page with a state that is also a cookie" {
    try ensureStarted(std.testing.io);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const res = try h.request(std.testing.io, a, app_port, "/auth/google", .{});
    try std.testing.expectEqual(@as(u16, 302), res.status);
    const location = res.header("Location").?;
    try std.testing.expect(std.mem.startsWith(u8, location, config.auth_endpoint));
    try std.testing.expectEqualStrings("client%201", valueOf(location, "client_id").?);
    try std.testing.expectEqualStrings("code", valueOf(location, "response_type").?);

    const set_cookie = res.header("Set-Cookie").?;
    try std.testing.expect(std.mem.indexOf(u8, set_cookie, "HttpOnly") != null);
    try std.testing.expect(std.mem.indexOf(u8, set_cookie, "SameSite=Lax") != null);

    // A state nobody can guess, and a new one each time.
    const first = try startLogin(a);
    const second = try startLogin(a);
    try std.testing.expect(first.state.len >= 32);
    try std.testing.expect(!std.mem.eql(u8, first.state, second.state));
}

test "google callback: the right state and a good code give the profile" {
    try ensureStarted(std.testing.io);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const started_login = try startLogin(a);
    const target = try std.fmt.allocPrint(a, "/auth/google/callback?code=good-code&state={s}", .{started_login.state});
    const res = try h.request(std.testing.io, a, app_port, target, .{ .headers = &.{started_login.cookie_line} });
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("1001|ana@example.com|Ana Ribeiro|https://example.com/ana.png", res.body);

    // clearState: the same cookie, emptied and expired.
    const cleared = res.header("Set-Cookie").?;
    try std.testing.expect(std.mem.startsWith(u8, cleared, spider.google.state_cookie ++ "=;"));
    try std.testing.expect(std.mem.indexOf(u8, cleared, "Max-Age=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, cleared, "Path=/") != null);
}

test "google callback: a state that is not this browser's is refused before any call to Google" {
    try ensureStarted(std.testing.io);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const started_login = try startLogin(a);

    // No cookie at all: a link someone else made.
    const no_cookie = try h.request(std.testing.io, a, app_port, try std.fmt.allocPrint(a, "/auth/google/callback?code=good-code&state={s}", .{started_login.state}), .{});
    try std.testing.expectEqual(@as(u16, 400), no_cookie.status);

    // A cookie, and another state in the address.
    const other_state = try h.request(std.testing.io, a, app_port, "/auth/google/callback?code=good-code&state=0000000000000000000000000000000f", .{ .headers = &.{started_login.cookie_line} });
    try std.testing.expectEqual(@as(u16, 400), other_state.status);

    // No state in the address.
    const no_state = try h.request(std.testing.io, a, app_port, "/auth/google/callback?code=good-code", .{ .headers = &.{started_login.cookie_line} });
    try std.testing.expectEqual(@as(u16, 400), no_state.status);
}

test "google callback: no code is a 400, a code Google refuses is a 401" {
    try ensureStarted(std.testing.io);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const started_login = try startLogin(a);
    const cookie: []const []const u8 = &.{started_login.cookie_line};

    const no_code = try h.request(std.testing.io, a, app_port, try std.fmt.allocPrint(a, "/auth/google/callback?state={s}", .{started_login.state}), .{ .headers = cookie });
    try std.testing.expectEqual(@as(u16, 400), no_code.status);

    const refused = try h.request(std.testing.io, a, app_port, try std.fmt.allocPrint(a, "/auth/google/callback?code=stale&state={s}", .{started_login.state}), .{ .headers = cookie });
    try std.testing.expectEqual(@as(u16, 401), refused.status);
}
