// End-to-end tests for spider.session and spider.password: an app with its
// own users logs one in with a signed cookie, and the middleware guards
// what is not public.

const std = @import("std");
const spider = @import("spider");

const Login = struct { email: []const u8 = "", password: []const u8 = "" };

// One account, its password hashed when the app starts.
var ana_hash: []const u8 = "";

fn login(c: *spider.Ctx) !spider.Response {
    const form = try c.parseForm(Login);
    const known = std.mem.eql(u8, form.email, "ana@example.com");
    const stored = if (known) ana_hash else spider.password.decoy;
    if (!spider.password.verify(c, stored, form.password) or !known) {
        return c.text("Wrong email or password.", .{ .status = .unprocessable_entity });
    }
    return c.redirectWith("/me", try spider.session.start(c, .{
        .id = "7",
        .email = form.email,
        .name = "Ana Ribeiro",
        .roles = &.{"editor"},
    }));
}

fn apiLogin(c: *spider.Ctx) !spider.Response {
    return c.json(.{ .token = try spider.session.token(c, .{ .id = "9", .name = "API client" }) }, .{});
}

fn logout(c: *spider.Ctx) !spider.Response {
    return c.redirectWith("/", try spider.session.end(c));
}

fn me(c: *spider.Ctx) !spider.Response {
    return c.text(try std.fmt.allocPrint(c.arena, "id={s} name={s} email={s} editor={}", .{
        c.userId().?,
        c.params.get("_auth_name") orelse "-",
        c.params.get("_auth_email") orelse "-",
        c.hasRole("editor"),
    }), .{});
}

fn home(c: *spider.Ctx) !spider.Response {
    return c.text(if (c.userId()) |id| id else "anonymous", .{});
}

fn admin(c: *spider.Ctx) !spider.Response {
    return c.text("admin area", .{});
}

fn onError(c: *spider.Ctx, err: anyerror) anyerror!spider.Response {
    return c.text(@errorName(err), .{ .status = spider.statusForError(err) });
}

fn run() !void {
    spider.session.options = .{ .secret = "e2e-session-secret" };
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    ana_hash = try spider.password.hashWith(std.heap.smp_allocator, threaded.io(), "open sesame 42");

    var server = spider.app(.{});
    defer server.deinit();
    try server
        .use(spider.session.middleware())
        .get("/", home, .{ .public = true })
        .post("/login", login, .{ .public = true })
        .post("/api/login", apiLogin, .{ .public = true })
        .post("/logout", logout, .{})
        .get("/me", me, .{ .authenticated = true })
        .get("/undeclared", me, .{})
        .get("/admin", admin, .{ .roles = &.{"admin"} })
        .onError(onError)
        .listen(.{});
}

fn cookieHeader(buf: []u8, res: spider.testing.Response) ![]const u8 {
    return std.fmt.bufPrint(buf, "Cookie: session={s}", .{res.cookie("session").?});
}

test "session: without one, public routes answer and the rest answer 401" {
    const app = try spider.testing.start(run);

    var open = try app.get("/");
    defer open.deinit();
    try open.expectStatus(200);
    try open.expectContains("anonymous");

    for ([_][]const u8{ "/me", "/undeclared", "/admin" }) |target| {
        var res = try app.get(target);
        defer res.deinit();
        try res.expectStatus(401);
    }

    // An address that is no route is a 404, not a request to log in.
    var nowhere = try app.get("/nowhere");
    defer nowhere.deinit();
    try nowhere.expectStatus(404);
}

test "session: the right password logs in, and the cookie identifies the user" {
    const app = try spider.testing.start(run);

    var wrong = try app.postForm("/login", .{ .email = "ana@example.com", .password = "open sesame 43" });
    defer wrong.deinit();
    try wrong.expectStatus(422);
    try std.testing.expect(wrong.cookie("session") == null);

    var nobody = try app.postForm("/login", .{ .email = "nobody@example.com", .password = "open sesame 42" });
    defer nobody.deinit();
    try nobody.expectStatus(422);

    var ok = try app.postForm("/login", .{ .email = "ana@example.com", .password = "open sesame 42" });
    defer ok.deinit();
    try ok.expectRedirect("/me");
    const set_cookie = ok.header("Set-Cookie").?;
    try std.testing.expect(std.mem.indexOf(u8, set_cookie, "HttpOnly") != null);
    try std.testing.expect(std.mem.indexOf(u8, set_cookie, "Secure") != null);
    try std.testing.expect(std.mem.indexOf(u8, set_cookie, "SameSite=Lax") != null);
    try std.testing.expect(std.mem.indexOf(u8, set_cookie, "Max-Age=1209600") != null);

    var buf: [1024]u8 = undefined;
    const cookie = try cookieHeader(&buf, ok);

    var mine = try app.request(.{ .target = "/me", .headers = &.{cookie} });
    defer mine.deinit();
    try mine.expectStatus(200);
    try mine.expectContains("id=7 name=Ana Ribeiro email=ana@example.com editor=true");

    // The same visitor, without repeating the cookie on every request.
    const ana = app.with(&.{cookie});
    var again = try ana.get("/me");
    defer again.deinit();
    try again.expectContains("id=7");
    var out = try ana.postForm("/logout", .{});
    defer out.deinit();
    try out.expectRedirect("/");

    var undeclared = try app.request(.{ .target = "/undeclared", .headers = &.{cookie} });
    defer undeclared.deinit();
    try undeclared.expectStatus(200);

    var home_page = try app.request(.{ .target = "/", .headers = &.{cookie} });
    defer home_page.deinit();
    try home_page.expectContains("7");

    // Logged in, but not an admin.
    var forbidden = try app.request(.{ .target = "/admin", .headers = &.{cookie} });
    defer forbidden.deinit();
    try forbidden.expectStatus(403);
}

test "session: a tampered cookie is no session" {
    const app = try spider.testing.start(run);
    var ok = try app.postForm("/login", .{ .email = "ana@example.com", .password = "open sesame 42" });
    defer ok.deinit();

    var buf: [1024]u8 = undefined;
    const cookie = try cookieHeader(&buf, ok);
    const last = cookie.len - 1;
    buf[last] = if (buf[last] == 'A') 'B' else 'A';

    var res = try app.request(.{ .target = "/me", .headers = &.{buf[0 .. last + 1]} });
    defer res.deinit();
    try res.expectStatus(401);

    var junk = try app.request(.{ .target = "/me", .headers = &.{"Cookie: session=not-a-token"} });
    defer junk.deinit();
    try junk.expectStatus(401);
}

test "session: logging out empties the cookie" {
    const app = try spider.testing.start(run);
    var ok = try app.postForm("/login", .{ .email = "ana@example.com", .password = "open sesame 42" });
    defer ok.deinit();
    var buf: [1024]u8 = undefined;
    const cookie = try cookieHeader(&buf, ok);

    var out = try app.request(.{ .method = "POST", .target = "/logout", .headers = &.{cookie} });
    defer out.deinit();
    try out.expectRedirect("/");
    try std.testing.expectEqualStrings("", out.cookie("session").?);
    try std.testing.expect(std.mem.indexOf(u8, out.header("Set-Cookie").?, "Max-Age=0") != null);

    // Logging out needs a session too.
    var anonymous = try app.request(.{ .method = "POST", .target = "/logout" });
    defer anonymous.deinit();
    try anonymous.expectStatus(401);
}

test "session: an API sends the token in the Authorization header" {
    const app = try spider.testing.start(run);
    var res = try app.request(.{ .method = "POST", .target = "/api/login" });
    defer res.deinit();
    try res.expectStatus(200);

    const start = std.mem.indexOf(u8, res.body, "\"token\":\"").? + "\"token\":\"".len;
    const end = std.mem.indexOfScalarPos(u8, res.body, start, '"').?;
    var buf: [1024]u8 = undefined;
    const header = try std.fmt.bufPrint(&buf, "Authorization: Bearer {s}", .{res.body[start..end]});

    var mine = try app.request(.{ .target = "/me", .headers = &.{header} });
    defer mine.deinit();
    try mine.expectStatus(200);
    try mine.expectContains("id=9 name=API client");

    // A header that is no token of ours next to a good cookie: the cookie
    // is what identifies the visitor.
    var signed_in = try app.postForm("/login", .{ .email = "ana@example.com", .password = "open sesame 42" });
    defer signed_in.deinit();
    try signed_in.expectRedirect("/me");
    var cookie_buf: [1024]u8 = undefined;
    const cookie = try cookieHeader(&cookie_buf, signed_in);
    var both = try app.request(.{ .target = "/me", .headers = &.{ "Authorization: Bearer nope", cookie } });
    defer both.deinit();
    try both.expectStatus(200);
    try both.expectContains("id=7");

    var bad = try app.request(.{ .target = "/me", .headers = &.{"Authorization: Bearer nope"} });
    defer bad.deinit();
    try bad.expectStatus(401);
}
