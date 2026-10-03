// End-to-end tests for the default (threaded) io_backend.
//
// Every test here drives the real request path — Server.listen() ->
// workerLoop() -> handleConnection() -> router -> middleware chain ->
// handler — over a real TCP socket, using a tiny raw HTTP/1.1 client so
// status codes, Location and Set-Cookie headers are observed exactly as a
// browser would receive them (no redirect following, no cookie jar).
//
// Not wired into `zig build test` (has side effects: binds real TCP
// listeners). Run explicitly: `zig build test-e2e`.

const std = @import("std");
const spider = @import("spider");

// ── raw HTTP client ─────────────────────────────────────────────────────

pub const HttpResponse = struct {
    status: u16,
    head: []const u8,
    body: []const u8,

    /// First header value named `name` (case-insensitive), or null.
    pub fn header(self: HttpResponse, name: []const u8) ?[]const u8 {
        var it = std.mem.splitSequence(u8, self.head, "\r\n");
        _ = it.next(); // status line
        while (it.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) {
                return std.mem.trim(u8, line[colon + 1 ..], " ");
            }
        }
        return null;
    }

    /// Number of header lines named `name` (case-insensitive).
    pub fn headerCount(self: HttpResponse, name: []const u8) usize {
        var n: usize = 0;
        var it = std.mem.splitSequence(u8, self.head, "\r\n");
        _ = it.next();
        while (it.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) n += 1;
        }
        return n;
    }
};

pub const RequestOptions = struct {
    method: []const u8 = "GET",
    /// Extra raw header lines, each WITHOUT the trailing CRLF.
    headers: []const []const u8 = &.{},
    body: ?[]const u8 = null,
};

/// Sends one request with `Connection: close` and reads the whole response.
pub fn request(io: std.Io, arena: std.mem.Allocator, port: u16, target: []const u8, opts: RequestOptions) !HttpResponse {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var wbuf: [4096]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    const w = &writer.interface;
    try w.print("{s} {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n", .{ opts.method, target });
    for (opts.headers) |h| try w.print("{s}\r\n", .{h});
    if (opts.body) |b| {
        try w.print("Content-Length: {d}\r\n\r\n{s}", .{ b.len, b });
    } else {
        try w.writeAll("\r\n");
    }
    try w.flush();

    var rbuf: [4096]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    const raw = try reader.interface.allocRemaining(arena, .limited(4 * 1024 * 1024));

    const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.MalformedResponse;
    const head = raw[0..head_end];
    const sp = std.mem.indexOfScalar(u8, head, ' ') orelse return error.MalformedResponse;
    const status = try std.fmt.parseInt(u16, head[sp + 1 .. sp + 4], 10);
    return .{ .status = status, .head = head, .body = raw[head_end + 4 ..] };
}

/// Binds port 0, reads back what the OS assigned, releases it. See
/// zio_backend_test.zig for why this small race window is acceptable.
pub fn reserveEphemeralPort(io: std.Io) !u16 {
    const probe_address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var probe = try probe_address.listen(io, .{ .reuse_address = true });
    defer probe.deinit(io);
    return probe.socket.address.getPort();
}

/// Polls until something accepts on `port` (max ~3s).
pub fn waitForPort(io: std.Io, port: u16) !void {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var tries: usize = 0;
    while (tries < 150) : (tries += 1) {
        if (address.connect(io, .{ .mode = .stream })) |s| {
            s.close(io);
            return;
        } else |_| {
            std.Io.sleep(io, .fromMilliseconds(20), .real) catch {};
        }
    }
    return error.ServerDidNotStart;
}

// ── shared test app ─────────────────────────────────────────────────────

/// Stand-in for the JWKS/Keycloak middleware: turns test headers into the
/// same `_auth_*` params the real provider injects.
///   X-Test-Roles: admin,staff          -> realm roles
///   X-Test-Orgs:  orgA=admin,orgB=resident -> organization roles
fn fakeAuth(c: *spider.Ctx, next: spider.NextFn) anyerror!spider.Response {
    if (c.header("X-Test-Roles")) |roles| {
        var i: usize = 0;
        var it = std.mem.splitScalar(u8, roles, ',');
        while (it.next()) |r| : (i += 1) {
            try c.params.put(c.arena, try std.fmt.allocPrint(c.arena, "_auth_role_{d}", .{i}), r);
        }
        try c.params.put(c.arena, "_auth_roles_count", try std.fmt.allocPrint(c.arena, "{d}", .{i}));
    }
    if (c.header("X-Test-Sub")) |sub| try c.params.put(c.arena, "_auth_sub", sub);
    if (c.header("X-Test-Orgs")) |orgs| {
        var i: usize = 0;
        var it = std.mem.splitScalar(u8, orgs, ',');
        while (it.next()) |pair| : (i += 1) {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.BadTestHeader;
            try c.params.put(c.arena, try std.fmt.allocPrint(c.arena, "_auth_org_{d}_id", .{i}), pair[0..eq]);
            try c.params.put(c.arena, try std.fmt.allocPrint(c.arena, "_auth_org_{d}_name", .{i}), pair[0..eq]);
            try c.params.put(c.arena, try std.fmt.allocPrint(c.arena, "_auth_org_{d}_role", .{i}), pair[eq + 1 ..]);
        }
        try c.params.put(c.arena, "_auth_orgs_count", try std.fmt.allocPrint(c.arena, "{d}", .{i}));
    }
    // Mirrors JwksConfig.active_org_cookie.
    if (c.cookie("active_org")) |org| try c.setActiveOrg(org);
    return next(c);
}

/// Yields (sleeps on the request's Io) BEFORE calling next — like a
/// middleware doing network I/O (JWKS refetch, a DB call on the request Io).
fn yieldingMiddleware(c: *spider.Ctx, next: spider.NextFn) anyerror!spider.Response {
    if (std.mem.startsWith(u8, c.getPath(), "/chain/")) {
        std.Io.sleep(c._io, .fromMilliseconds(5), .real) catch {};
    }
    return next(c);
}

fn chainA(c: *spider.Ctx) !spider.Response {
    return c.text("A", .{});
}

fn chainB(c: *spider.Ctx) !spider.Response {
    return c.text("B", .{});
}

fn ok(c: *spider.Ctx) !spider.Response {
    const id = c.params.get("id") orelse "-";
    return c.text(try std.fmt.allocPrint(c.arena, "ok:{s}", .{id}), .{});
}

fn errorHandler(c: *spider.Ctx, err: anyerror) !spider.Response {
    return switch (err) {
        error.Forbidden => c.text("forbidden", .{ .status = .forbidden }),
        else => c.text(
            try std.fmt.allocPrint(c.arena, "onError:{s}:{s}", .{ @errorName(err), c.errorDetail() orelse "" }),
            .{ .status = spider.statusForError(err) },
        ),
    };
}

fn typed(id: spider.Path(i64, "id"), c: *spider.Ctx) !spider.Response {
    return c.text(try std.fmt.allocPrint(c.arena, "typed:{d}", .{id.value}), .{});
}

const admin = &[_][]const u8{"admin"};

/// Group.use() middleware: tags every response it wraps.
fn tagGroup(c: *spider.Ctx, next: spider.NextFn) anyerror!spider.Response {
    var resp = try next(c);
    const hdrs = try c.arena.alloc([2][]const u8, resp.headers.len + 1);
    @memcpy(hdrs[0..resp.headers.len], resp.headers);
    hdrs[resp.headers.len] = .{ "X-Group", "g2" };
    resp.headers = hdrs;
    return resp;
}

/// Echoes what the matched route declared (c.route()).
/// Both query accessors side by side: raw (as documented) and decoded once.
fn queryEcho(c: *spider.Ctx) !spider.Response {
    return c.text(try std.fmt.allocPrint(c.arena, "raw=[{s}] decoded=[{s}]", .{ c.query("q") orelse "-", c.queryDecoded("q") orelse "-" }), .{});
}

fn metaEcho(c: *spider.Ctx) !spider.Response {
    const m = c.route();
    return c.text(try std.fmt.allocPrint(c.arena, "public={} quiet_log={} allow_http={} org_roles={d}", .{ m.public, m.quiet_log, m.allow_http, m.org_roles.len }), .{});
}

/// An app's own login (no JWT): the session names a user whose roles live
/// in the app's database, put on the request with the identity API.
///   X-Session: 1 -> user 1: role editor, manager of org c1
///   X-Session: 2 -> user 2: no roles
///   X-Session: 3 -> user 3: role admin
fn dbSession(c: *spider.Ctx, next: spider.NextFn) anyerror!spider.Response {
    const sid = c.header("X-Session") orelse return next(c);
    try c.setUser(.{ .id = sid });
    if (std.mem.eql(u8, sid, "1")) {
        try c.addRole("editor");
        try c.addOrgRole(.{ .org_id = "c1", .org_name = "Tower A", .role = "manager" });
    }
    if (std.mem.eql(u8, sid, "3")) try c.addRole("admin");
    return next(c);
}

/// Post 10 belongs to user 1.
fn ownsPost(c: *spider.Ctx) !bool {
    const id = c.params.get("id") orelse return false;
    return std.mem.eql(u8, id, "10") and std.mem.eql(u8, c.userId() orelse "", "1");
}

const Doc = struct { id: u32, owner: []const u8, title: []const u8 };

/// Docs 10 (user 1's) and 11 (user 2's), as if from the database.
fn loadDoc(c: *spider.Ctx) !?Doc {
    const id = std.fmt.parseInt(u32, c.params.get("id") orelse return null, 10) catch return null;
    return switch (id) {
        10 => .{ .id = 10, .owner = "1", .title = "plan" },
        11 => .{ .id = 11, .owner = "2", .title = "budget" },
        else => null,
    };
}

fn ownsDoc(c: *spider.Ctx, doc: *const Doc) bool {
    return std.mem.eql(u8, doc.owner, c.userId() orelse "");
}

fn showDoc(doc: spider.Loaded(Doc), c: *spider.Ctx) !spider.Response {
    return c.text(try std.fmt.allocPrint(c.arena, "doc {d}: {s}", .{ doc.value.id, doc.value.title }), .{});
}

fn canViewDoc(c: *spider.Ctx, doc: *const Doc) bool {
    return ownsDoc(c, doc) or c.hasRole("admin");
}

const Docs = spider.policySet(Doc, .{
    .name = "doc",
    .load = loadDoc,
    .rules = .{ .view = canViewDoc, .update = ownsDoc },
});

fn docPage(doc: spider.Loaded(Doc), c: *spider.Ctx) !spider.Response {
    const can_edit = try Docs.can(c, .update, doc.value);
    return c.text(try std.fmt.allocPrint(c.arena, "{s} can_edit={}", .{ doc.value.title, can_edit }), .{});
}

fn runApp(port: u16) void {
    var s = spider.app(.{});

    // Group parity + defaults: admin (active org) unless a route says otherwise.
    var g2 = spider.Group.init("/g2");
    _ = g2
        .defaults(.{ .org_roles = admin })
        .get("/inherit/:id", ok, .{})
        .get("/open", ok, .{ .public = true })
        .post("/staff/:id", ok, .{ .roles = &.{"staff"} })
        .get("/typed/:id", typed, .{})
        .patch("/p/:id", ok, .{})
        .head("/h", ok, .{})
        .get("/meta", metaEcho, .{ .quiet_log = true, .allow_http = true })
        .use(tagGroup); // after the routes on purpose: applies to all of them

    var gl = spider.Group.init("/logged");
    _ = gl
        .defaults(.{ .authenticated = true })
        .get("/me", ok, .{})
        .get("/admin", ok, .{ .roles = admin })
        .get("/open", ok, .{ .public = true });

    var own = spider.Group.init("/own");
    _ = own
        .defaults(.{ .authenticated = true })
        .get("/me", ok, .{})
        .get("/editor", ok, .{ .roles = &.{"editor"} })
        .get("/org", ok, .{ .org_roles = &.{"manager"} })
        .post("/posts/:id/edit", ok, .{ .policy = spider.policy("post_owner", ownsPost) })
        .get("/docs/:id", showDoc, .{ .policy = spider.resourcePolicy("doc_owner", Doc, .{ .load = loadDoc, .check = ownsDoc }) })
        .get("/set/:id", docPage, .{ .policy = Docs.route(.view) })
        .post("/set/:id", showDoc, .{ .policy = Docs.route(.update) })
        .get("/private/:id", showDoc, .{ .policy = spider.resourcePolicy("doc_owner", Doc, .{ .load = loadDoc, .check = ownsDoc, .deny = .not_found }) });

    var g = spider.Group.init("/g");
    _ = g
        .get("/things", ok, .{ .org_roles = admin })
        .get("/things/:id", ok, .{ .org_roles = admin })
        .post("/things/:id/edit", ok, .{ .roles = admin })
        .get("/open/:id", ok, .{});

    s
        .use(fakeAuth)
        .use(yieldingMiddleware)
        .useAt("/own", dbSession)
        .get("/q/echo", queryEcho, .{ .public = true })
        .get("/chain/a", chainA, .{})
        .get("/chain/b", chainB, .{})
        .get("/r/static", ok, .{ .roles = admin })
        .get("/r/items/:id", ok, .{ .roles = admin })
        .post("/r/items/:id", ok, .{ .roles = admin })
        .put("/r/items/:id", ok, .{ .roles = admin })
        .delete("/r/items/:id", ok, .{ .roles = admin })
        .patch("/r/items/:id", ok, .{ .roles = admin })
        .get("/r/items/:id/sub/:sub", ok, .{ .roles = admin })
        .get("/r/files/*", ok, .{ .roles = admin })
        .get("/r/org/:id", ok, .{ .org_roles = admin })
        .get("/r/both/:id", ok, .{ .roles = &.{"staff"}, .org_roles = admin })
        // Same shape, different RBAC — a public static route must not pick up
        // the RBAC of the dynamic sibling it happens to also match, and
        // vice versa.
        .get("/amb/new", ok, .{})
        .get("/amb/:id", ok, .{ .roles = admin })
        .get("/public/:id", ok, .{})
        .get("/typed/:id", typed, .{})
        .mount(g)
        .mount(g2)
        .mount(gl)
        .mount(own)
        .get("/meta/public", metaEcho, .{ .public = true })
        .get("/ip", clientIpEcho, .{})
        .onError(errorHandler)
        .listen(.{ .port = port, .host = "127.0.0.1" }) catch |err| {
        std.log.err("e2e app listen() failed: {s}", .{@errorName(err)});
    };
}

var app_port: ?u16 = null;
var app_once_mutex: std.Io.Mutex = .init;

/// Starts the shared app once per test process (listen() never returns, so
/// its thread is detached — see zio_backend_test.zig).
fn appPort(io: std.Io) !u16 {
    try app_once_mutex.lock(io);
    defer app_once_mutex.unlock(io);
    if (app_port) |p| return p;
    const port = try reserveEphemeralPort(io);
    const t = try std.Thread.spawn(.{}, runApp, .{port});
    t.detach();
    try waitForPort(io, port);
    app_port = port;
    return port;
}

const TestEnv = struct {
    threaded: std.Io.Threaded,
    arena: std.heap.ArenaAllocator,

    fn init() TestEnv {
        return .{
            .threaded = .init(std.testing.allocator, .{}),
            .arena = .init(std.testing.allocator),
        };
    }
    fn deinit(self: *TestEnv) void {
        self.arena.deinit();
        self.threaded.deinit();
    }
    fn io(self: *TestEnv) std.Io {
        return self.threaded.io();
    }
};

fn expectStatus(expected: u16, env: *TestEnv, target: []const u8, opts: RequestOptions) !void {
    const port = try appPort(env.io());
    const res = try request(env.io(), env.arena.allocator(), port, target, opts);
    if (res.status != expected) {
        std.debug.print("\n{s} {s}: expected {d}, got {d} (body: {s})\n", .{ opts.method, target, expected, res.status, res.body });
    }
    try std.testing.expectEqual(expected, res.status);
}

// ── RBAC on routes (item 1) ─────────────────────────────────────────────

test "queryDecoded: + is a space, %2B stays a plus, UTF-8 escapes decode once; query() stays raw" {
    var env = TestEnv.init();
    defer env.deinit();
    const port = try appPort(env.io());
    const cases = [_][2][]const u8{
        .{ "/q/echo?q=Paulo+Ficks", "raw=[Paulo+Ficks] decoded=[Paulo Ficks]" },
        .{ "/q/echo?q=%2B55%2075", "raw=[%2B55%2075] decoded=[+55 75]" },
        .{ "/q/echo?q=Jo%C3%A3o", "raw=[Jo%C3%A3o] decoded=[Jo\u{e3}o]" },
        .{ "/q/echo?q=%252F", "raw=[%252F] decoded=[%2F]" },
        .{ "/q/echo?q=100%", "raw=[100%] decoded=[100%]" },
        .{ "/q/echo?other=1", "raw=[-] decoded=[-]" },
    };
    for (cases) |tc| {
        const res = try request(env.io(), env.arena.allocator(), port, tc[0], .{});
        try std.testing.expectEqual(@as(u16, 200), res.status);
        try std.testing.expectEqualStrings(tc[1], res.body);
    }
}

test "rbac: static route denies without role and allows with it" {
    var env = TestEnv.init();
    defer env.deinit();
    try expectStatus(403, &env, "/r/static", .{});
    try expectStatus(403, &env, "/r/static", .{ .headers = &.{"X-Test-Roles: viewer"} });
    try expectStatus(200, &env, "/r/static", .{ .headers = &.{"X-Test-Roles: admin"} });
}

test "rbac: route with :param denies without role" {
    var env = TestEnv.init();
    defer env.deinit();
    try expectStatus(403, &env, "/r/items/42", .{});
    try expectStatus(403, &env, "/r/items/42", .{ .headers = &.{"X-Test-Roles: viewer"} });
    try expectStatus(200, &env, "/r/items/42", .{ .headers = &.{"X-Test-Roles: admin"} });
}

test "rbac: every HTTP method on a :param route is enforced" {
    var env = TestEnv.init();
    defer env.deinit();
    for ([_][]const u8{ "POST", "PUT", "DELETE", "PATCH" }) |m| {
        try expectStatus(403, &env, "/r/items/7", .{ .method = m, .body = "" });
        try expectStatus(200, &env, "/r/items/7", .{ .method = m, .body = "", .headers = &.{"X-Test-Roles: admin"} });
    }
}

test "rbac: multi-param and wildcard routes are enforced" {
    var env = TestEnv.init();
    defer env.deinit();
    try expectStatus(403, &env, "/r/items/1/sub/2", .{});
    try expectStatus(200, &env, "/r/items/1/sub/2", .{ .headers = &.{"X-Test-Roles: admin"} });
    try expectStatus(403, &env, "/r/files/report.pdf", .{});
    try expectStatus(200, &env, "/r/files/report.pdf", .{ .headers = &.{"X-Test-Roles: admin"} });
}

test "rbac: org_roles on :param route is enforced" {
    var env = TestEnv.init();
    defer env.deinit();
    try expectStatus(403, &env, "/r/org/9", .{});
    try expectStatus(403, &env, "/r/org/9", .{ .headers = &.{"X-Test-Orgs: orgA=resident"} });
    try expectStatus(200, &env, "/r/org/9", .{ .headers = &.{"X-Test-Orgs: orgA=admin"} });
}

test "rbac: roles and org_roles on the same route are BOTH required" {
    var env = TestEnv.init();
    defer env.deinit();
    try expectStatus(403, &env, "/r/both/1", .{ .headers = &.{"X-Test-Roles: staff"} });
    try expectStatus(403, &env, "/r/both/1", .{ .headers = &.{"X-Test-Orgs: orgA=admin"} });
    try expectStatus(200, &env, "/r/both/1", .{ .headers = &.{ "X-Test-Roles: staff", "X-Test-Orgs: orgA=admin" } });
}

test "rbac: static route does not inherit RBAC of a dynamic sibling" {
    var env = TestEnv.init();
    defer env.deinit();
    try expectStatus(200, &env, "/amb/new", .{});
    try expectStatus(403, &env, "/amb/5", .{});
    try expectStatus(200, &env, "/amb/5", .{ .headers = &.{"X-Test-Roles: admin"} });
}

test "rbac: public :param route stays public" {
    var env = TestEnv.init();
    defer env.deinit();
    try expectStatus(200, &env, "/public/abc", .{});
}

test "rbac: Group-mounted routes enforce roles, with and without :param" {
    var env = TestEnv.init();
    defer env.deinit();
    try expectStatus(403, &env, "/g/things", .{});
    try expectStatus(200, &env, "/g/things", .{ .headers = &.{"X-Test-Orgs: orgA=admin"} });
    try expectStatus(403, &env, "/g/things/3", .{});
    try expectStatus(200, &env, "/g/things/3", .{ .headers = &.{"X-Test-Orgs: orgA=admin"} });
    try expectStatus(403, &env, "/g/things/3/edit", .{ .method = "POST", .body = "" });
    try expectStatus(200, &env, "/g/things/3/edit", .{ .method = "POST", .body = "", .headers = &.{"X-Test-Roles: admin"} });
    try expectStatus(200, &env, "/g/open/3", .{});
}

// ── cross-site request check (on by default) ────────────────────────────

test "origin check: a cross-site POST from a browser is refused with 403 before routing" {
    var env = TestEnv.init();
    defer env.deinit();
    const admin_post: RequestOptions = .{ .method = "POST", .body = "", .headers = &.{ "X-Test-Roles: admin", "Sec-Fetch-Site: cross-site", "Origin: https://evil.example" } };
    try expectStatus(403, &env, "/r/items/1", admin_post);
    try expectStatus(403, &env, "/r/items/1", .{ .method = "POST", .body = "", .headers = &.{ "X-Test-Roles: admin", "Origin: https://evil.example" } });
}

test "origin check: same-origin browsers, matching Origin and non-browser clients pass" {
    var env = TestEnv.init();
    defer env.deinit();
    try expectStatus(200, &env, "/r/items/1", .{ .method = "POST", .body = "", .headers = &.{ "X-Test-Roles: admin", "Sec-Fetch-Site: same-origin", "Origin: http://127.0.0.1" } });
    try expectStatus(200, &env, "/r/items/1", .{ .method = "POST", .body = "", .headers = &.{ "X-Test-Roles: admin", "Origin: http://127.0.0.1" } });
    try expectStatus(200, &env, "/r/items/1", .{ .method = "POST", .body = "", .headers = &.{"X-Test-Roles: admin"} });
    // Safe methods are never checked.
    try expectStatus(200, &env, "/r/items/1", .{ .headers = &.{ "X-Test-Roles: admin", "Sec-Fetch-Site: cross-site", "Origin: https://evil.example" } });
}

test "clientIp: X-Forwarded-For is ignored without trusted proxies, used behind one" {
    var env = TestEnv.init();
    defer env.deinit();
    const direct = try request(env.io(), env.arena.allocator(), try appPort(env.io()), "/ip", .{ .headers = &.{"X-Forwarded-For: 203.0.113.7"} });
    try std.testing.expectEqualStrings("127.0.0.1", direct.body);
    const proxied = try request(env.io(), env.arena.allocator(), try deadlineAppPort(env.io()), "/ip", .{ .headers = &.{"X-Forwarded-For: 6.6.6.6, 203.0.113.7"} });
    try std.testing.expectEqualStrings("203.0.113.7", proxied.body);
}

// ── roles from the app itself, policies ─────────────────────────────────

test "identity API: an app's own session and roles drive .authenticated, .roles and .org_roles" {
    var env = TestEnv.init();
    defer env.deinit();
    try expectStatus(401, &env, "/own/me", .{});
    try expectStatus(200, &env, "/own/me", .{ .headers = &.{"X-Session: 2"} });
    try expectStatus(403, &env, "/own/editor", .{ .headers = &.{"X-Session: 2"} });
    try expectStatus(200, &env, "/own/editor", .{ .headers = &.{"X-Session: 1"} });
    try expectStatus(403, &env, "/own/org", .{ .headers = &.{"X-Session: 2"} });
    try expectStatus(200, &env, "/own/org", .{ .headers = &.{"X-Session: 1"} });
}

test "policy: 401 anonymous, 403 for another user, 200 for the owner" {
    var env = TestEnv.init();
    defer env.deinit();
    const edit: RequestOptions = .{ .method = "POST", .body = "" };
    try expectStatus(401, &env, "/own/posts/10/edit", edit);
    try expectStatus(403, &env, "/own/posts/10/edit", .{ .method = "POST", .body = "", .headers = &.{"X-Session: 2"} });
    try expectStatus(200, &env, "/own/posts/10/edit", .{ .method = "POST", .body = "", .headers = &.{"X-Session: 1"} });
    try expectStatus(403, &env, "/own/posts/11/edit", .{ .method = "POST", .body = "", .headers = &.{"X-Session: 1"} });
}

test "resourcePolicy: 401 anonymous, 404 missing, 403 someone else's, the owner's handler gets the loaded doc" {
    var env = TestEnv.init();
    defer env.deinit();
    try expectStatus(401, &env, "/own/docs/10", .{});
    try expectStatus(401, &env, "/own/docs/99", .{}); // anonymous can't tell missing from existing
    try expectStatus(404, &env, "/own/docs/99", .{ .headers = &.{"X-Session: 1"} });
    try expectStatus(403, &env, "/own/docs/11", .{ .headers = &.{"X-Session: 1"} });
    try expectStatus(200, &env, "/own/docs/10", .{ .headers = &.{"X-Session: 1"} });
    const res = try request(env.io(), env.arena.allocator(), try appPort(env.io()), "/own/docs/11", .{ .headers = &.{"X-Session: 2"} });
    try std.testing.expectEqualStrings("doc 11: budget", res.body);
}

test "resourcePolicy with .deny = .not_found: someone else's doc looks missing" {
    var env = TestEnv.init();
    defer env.deinit();
    try expectStatus(404, &env, "/own/private/11", .{ .headers = &.{"X-Session: 1"} });
    try expectStatus(404, &env, "/own/private/99", .{ .headers = &.{"X-Session: 1"} });
    try expectStatus(200, &env, "/own/private/10", .{ .headers = &.{"X-Session: 1"} });
}

test "policySet: route(.view) lets the owner and admins in; can(.update) tells the handler who may edit" {
    var env = TestEnv.init();
    defer env.deinit();
    const port = try appPort(env.io());
    const owner = try request(env.io(), env.arena.allocator(), port, "/own/set/10", .{ .headers = &.{"X-Session: 1"} });
    try std.testing.expectEqualStrings("plan can_edit=true", owner.body);
    const by_admin = try request(env.io(), env.arena.allocator(), port, "/own/set/10", .{ .headers = &.{"X-Session: 3"} });
    try std.testing.expectEqualStrings("plan can_edit=false", by_admin.body);
    try expectStatus(403, &env, "/own/set/10", .{ .headers = &.{"X-Session: 2"} });
    try expectStatus(404, &env, "/own/set/99", .{ .headers = &.{"X-Session: 1"} });
    try expectStatus(401, &env, "/own/set/10", .{});
    try expectStatus(403, &env, "/own/set/10", .{ .method = "POST", .body = "", .headers = &.{"X-Session: 3"} });
    try expectStatus(200, &env, "/own/set/10", .{ .method = "POST", .body = "", .headers = &.{"X-Session: 1"} });
}

// ── active org (item 3) ─────────────────────────────────────────────────

test "org rbac: role in another org does not open a route while this org is active" {
    var env = TestEnv.init();
    defer env.deinit();
    const orgs = "X-Test-Orgs: orgA=admin,orgB=resident";
    try expectStatus(403, &env, "/r/org/1", .{ .headers = &.{ orgs, "Cookie: active_org=orgB" } });
    try expectStatus(200, &env, "/r/org/1", .{ .headers = &.{ orgs, "Cookie: active_org=orgA" } });
    try expectStatus(403, &env, "/g/things", .{ .headers = &.{ orgs, "Cookie: active_org=orgB" } });
}

test "org rbac: forged active org cookie for a non-member org is denied" {
    var env = TestEnv.init();
    defer env.deinit();
    try expectStatus(403, &env, "/r/org/1", .{ .headers = &.{ "X-Test-Orgs: orgA=admin", "Cookie: active_org=orgZ" } });
}

test "org rbac: no active org keeps any-org behavior" {
    var env = TestEnv.init();
    defer env.deinit();
    try expectStatus(200, &env, "/r/org/1", .{ .headers = &.{"X-Test-Orgs: orgA=admin,orgB=resident"} });
}

test {
    _ = @import("e2e/keycloak_test.zig");
    _ = @import("e2e/sse_test.zig");
    _ = @import("e2e/mail_test.zig");
}

// ── middleware chain isolation ──────────────────────────────────────────

const ChainJob = struct {
    port: u16,
    target: []const u8,
    expect: []const u8,
    wrong: *std.atomic.Value(u32),
    errors: *std.atomic.Value(u32),
};

fn chainWorker(job: ChainJob) void {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    for (0..10) |_| {
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        const res = request(threaded.io(), arena.allocator(), job.port, job.target, .{}) catch {
            _ = job.errors.fetchAdd(1, .seq_cst);
            continue;
        };
        if (!std.mem.eql(u8, res.body, job.expect)) _ = job.wrong.fetchAdd(1, .seq_cst);
    }
}

test "middleware chain: a middleware that yields before next() never runs another request's handler" {
    var env = TestEnv.init();
    defer env.deinit();
    const port = try appPort(env.io());

    var wrong = std.atomic.Value(u32).init(0);
    var errors = std.atomic.Value(u32).init(0);
    var threads: [16]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        const is_a = i % 2 == 0;
        t.* = try std.Thread.spawn(.{}, chainWorker, .{ChainJob{
            .port = port,
            .target = if (is_a) "/chain/a" else "/chain/b",
            .expect = if (is_a) "A" else "B",
            .wrong = &wrong,
            .errors = &errors,
        }});
    }
    for (threads) |t| t.join();
    if (wrong.load(.seq_cst) > 0 or errors.load(.seq_cst) > 0) {
        std.debug.print("\n  160 requests: {d} got another route's response, {d} failed\n", .{ wrong.load(.seq_cst), errors.load(.seq_cst) });
    }
    try std.testing.expectEqual(@as(u32, 0), wrong.load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 0), errors.load(.seq_cst));
}

// ── request id, error routing, unreadable bodies ────────────────────────

test "request id: generated when absent, echoed as X-Request-Id" {
    var env = TestEnv.init();
    defer env.deinit();
    const port = try appPort(env.io());
    const a = try request(env.io(), env.arena.allocator(), port, "/public/1", .{});
    const b = try request(env.io(), env.arena.allocator(), port, "/public/1", .{});
    const ra = a.header("X-Request-Id").?;
    try std.testing.expectEqual(@as(usize, 16), ra.len);
    try std.testing.expect(!std.mem.eql(u8, ra, b.header("X-Request-Id").?));
}

test "request id: a sane incoming X-Request-Id is kept, a bad one replaced" {
    var env = TestEnv.init();
    defer env.deinit();
    const port = try appPort(env.io());
    const kept = try request(env.io(), env.arena.allocator(), port, "/public/1", .{ .headers = &.{"X-Request-Id: proxy-abc_123.4"} });
    try std.testing.expectEqualStrings("proxy-abc_123.4", kept.header("X-Request-Id").?);
    const bad = try request(env.io(), env.arena.allocator(), port, "/public/1", .{ .headers = &.{"X-Request-Id: bad id <script>"} });
    try std.testing.expectEqual(@as(usize, 16), bad.header("X-Request-Id").?.len);
}

test "unknown route goes through onError as NotFound (404)" {
    var env = TestEnv.init();
    defer env.deinit();
    const port = try appPort(env.io());
    const res = try request(env.io(), env.arena.allocator(), port, "/definitely/not/here", .{});
    try std.testing.expectEqual(@as(u16, 404), res.status);
    try std.testing.expectEqualStrings("onError:NotFound:", res.body);
}

test "extractor failure reaches onError with its detail (400)" {
    var env = TestEnv.init();
    defer env.deinit();
    const port = try appPort(env.io());
    const res = try request(env.io(), env.arena.allocator(), port, "/typed/abc", .{});
    try std.testing.expectEqual(@as(u16, 400), res.status);
    try std.testing.expectEqualStrings("onError:InvalidPathParam:invalid path param: id", res.body);
    const good = try request(env.io(), env.arena.allocator(), port, "/typed/7", .{});
    try std.testing.expectEqualStrings("typed:7", good.body);
}

test "truncated request body -> 400, not a misleading BodyEmpty" {
    var env = TestEnv.init();
    defer env.deinit();
    const io = env.io();
    const port = try appPort(io);
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [512]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    // Promises 100 bytes, sends 10, then stops sending.
    try w.interface.writeAll("POST /r/items/1 HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nname=short");
    try w.interface.flush();
    try stream.shutdown(io, .send);
    var rbuf: [1024]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    const raw = try r.interface.allocRemaining(env.arena.allocator(), .limited(64 * 1024));
    try std.testing.expect(std.mem.startsWith(u8, raw, "HTTP/1.1 400"));
    try std.testing.expect(std.mem.indexOf(u8, raw, "Could not read request body") != null);
}

// ── connection deadlines and the accept loop ───────────────────────────
// Dedicated apps: one with very short deadlines, one left at the defaults
// for the fd-exhaustion test (which would take the shared app down if the
// accept loop still died).

const short_ms: u32 = 300;
/// Client-side guard: if the server hasn't closed the connection by then,
/// the deadline didn't fire.
const guard_ms: u32 = 3000;

fn fast(c: *spider.Ctx) !spider.Response {
    return c.text("fast", .{});
}

fn slowHandler(c: *spider.Ctx) !spider.Response {
    std.Io.sleep(c._io, .fromMilliseconds(1000), .real) catch {};
    return c.text("slow", .{});
}

fn clientIpEcho(c: *spider.Ctx) !spider.Response {
    return c.text(c.clientIp() orelse "-", .{});
}

fn bodyLen(c: *spider.Ctx) !spider.Response {
    const len = if (c.body) |b| b.len else 0;
    return c.text(try std.fmt.allocPrint(c.arena, "{d}", .{len}), .{});
}

fn runDeadlineApp(port: u16) void {
    var s = spider.appWithConfig(.{
        .views_dir = null,
        .static_dir = null,
        .keepalive_timeout_ms = short_ms,
        .header_timeout_ms = short_ms,
        .body_timeout_ms = short_ms,
        .max_body_bytes = 1024,
        .trusted_proxies = &.{"127.0.0.1"},
        .workers = 2,
    });
    s.get("/fast", fast, .{})
        .get("/ip", clientIpEcho, .{})
        .get("/slow", slowHandler, .{})
        .post("/len", bodyLen, .{})
        .listen(.{ .port = port, .host = "127.0.0.1" }) catch |err| {
        std.log.err("deadline app listen() failed: {s}", .{@errorName(err)});
    };
}

fn runPlainApp(port: u16) void {
    var s = spider.appWithConfig(.{ .views_dir = null, .static_dir = null });
    s.get("/fast", fast, .{}).listen(.{ .port = port, .host = "127.0.0.1" }) catch |err| {
        std.log.err("plain app listen() failed: {s}", .{@errorName(err)});
    };
}

var deadline_port: ?u16 = null;
fn deadlineAppPort(io: std.Io) !u16 {
    try app_once_mutex.lock(io);
    defer app_once_mutex.unlock(io);
    if (deadline_port) |p| return p;
    const port = try reserveEphemeralPort(io);
    (try std.Thread.spawn(.{}, runDeadlineApp, .{port})).detach();
    try waitForPort(io, port);
    deadline_port = port;
    return port;
}

const Read = struct { bytes: []const u8, ms: i64, closed_by_server: bool };

fn guardThread(io: std.Io, fd: std.posix.fd_t, fired: *std.atomic.Value(bool), done: *std.atomic.Value(bool)) void {
    var waited: u32 = 0;
    while (waited < guard_ms and !done.load(.acquire)) : (waited += 20) {
        std.Io.sleep(io, .fromMilliseconds(20), .real) catch {};
    }
    if (!done.load(.acquire)) {
        fired.store(true, .release);
        _ = std.c.shutdown(fd, std.c.SHUT.RDWR);
    }
}

/// Reads until the server closes the connection, or until the guard gives
/// up after `guard_ms` (then closed_by_server = false).
fn readUntilClose(io: std.Io, arena: std.mem.Allocator, stream: std.Io.net.Stream) !Read {
    var fired: std.atomic.Value(bool) = .init(false);
    var done: std.atomic.Value(bool) = .init(false);
    const t = try std.Thread.spawn(.{}, guardThread, .{ io, stream.socket.handle, &fired, &done });
    const start = std.Io.Clock.now(.awake, io);
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    const bytes: []const u8 = r.interface.allocRemaining(arena, .limited(64 * 1024)) catch "";
    const ms = @divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - start.nanoseconds, std.time.ns_per_ms);
    done.store(true, .release);
    t.join();
    return .{ .bytes = bytes, .ms = @intCast(ms), .closed_by_server = !fired.load(.acquire) };
}

fn connectTo(io: std.Io, port: u16) !std.Io.net.Stream {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    return address.connect(io, .{ .mode = .stream });
}

fn send(io: std.Io, stream: std.Io.net.Stream, bytes: []const u8) !void {
    var wbuf: [512]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

test "deadline: a connection that never sends anything is closed" {
    var env = TestEnv.init();
    defer env.deinit();
    const io = env.io();
    const stream = try connectTo(io, try deadlineAppPort(io));
    defer stream.close(io);
    const r = try readUntilClose(io, env.arena.allocator(), stream);
    try std.testing.expect(r.closed_by_server);
    try std.testing.expectEqual(@as(usize, 0), r.bytes.len);
}

test "deadline: a request head that never finishes (slowloris) is closed" {
    var env = TestEnv.init();
    defer env.deinit();
    const io = env.io();
    const stream = try connectTo(io, try deadlineAppPort(io));
    defer stream.close(io);
    try send(io, stream, "GET /fast HTTP/1.1\r\nHost: x\r\n");
    const r = try readUntilClose(io, env.arena.allocator(), stream);
    try std.testing.expect(r.closed_by_server);
    try std.testing.expectEqual(@as(usize, 0), r.bytes.len);
}

test "deadline: a body that stops arriving gets 400 and the connection closed" {
    var env = TestEnv.init();
    defer env.deinit();
    const io = env.io();
    const stream = try connectTo(io, try deadlineAppPort(io));
    defer stream.close(io);
    try send(io, stream, "POST /len HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nabc");
    const r = try readUntilClose(io, env.arena.allocator(), stream);
    try std.testing.expect(r.closed_by_server);
    try std.testing.expect(std.mem.startsWith(u8, r.bytes, "HTTP/1.1 400"));
}

test "body limit: a declared body over max_body_bytes gets 413 before it is read" {
    var env = TestEnv.init();
    defer env.deinit();
    const io = env.io();
    const stream = try connectTo(io, try deadlineAppPort(io));
    defer stream.close(io);
    // Declares 4 GB and sends nothing: answered at once, nothing allocated.
    try send(io, stream, "POST /len HTTP/1.1\r\nHost: x\r\nContent-Length: 4000000000\r\n\r\n");
    const r = try readUntilClose(io, env.arena.allocator(), stream);
    try std.testing.expect(r.closed_by_server);
    try std.testing.expect(std.mem.startsWith(u8, r.bytes, "HTTP/1.1 413"));
}

test "body limit: a body within max_body_bytes is read as before" {
    var env = TestEnv.init();
    defer env.deinit();
    const io = env.io();
    const stream = try connectTo(io, try deadlineAppPort(io));
    defer stream.close(io);
    const body: [1024]u8 = @splat('x');
    try send(io, stream, "POST /len HTTP/1.1\r\nHost: x\r\nContent-Length: 1024\r\nConnection: close\r\n\r\n" ++ body);
    const r = try readUntilClose(io, env.arena.allocator(), stream);
    try std.testing.expect(std.mem.startsWith(u8, r.bytes, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.endsWith(u8, r.bytes, "1024"));
}

// ── Large bodies keep the request head intact ────────────────────────────
// Path, headers and request id were slices into the connection's read
// buffer; reading a body larger than that buffer overwrote them. The route
// then failed to match (no `.public` meta, so an auth middleware redirected)
// and headers read back body bytes. Seen in production with Intelbras
// devices posting events with a photo: every one got 302 to the login.

fn requirePublic(c: *spider.Ctx, next: spider.NextFn) !spider.Response {
    if (!c.route().public) return c.text("unauthenticated", .{ .status = .unauthorized });
    return next(c);
}

fn deviceEcho(c: *spider.Ctx) !spider.Response {
    const len = if (c.body) |b| b.len else 0;
    const last: u8 = if (c.body) |b| (if (b.len > 0) b[b.len - 1] else '-') else '-';
    return c.text(try std.fmt.allocPrint(c.arena, "path={s} device={s} type={s} rid={s} len={d} last={c}", .{
        c.getPath(), c.header("X-Device") orelse "-", c.header("Content-Type") orelse "-", c.requestId(), len, last,
    }), .{});
}

fn runLargeBodyApp(port: u16) void {
    var s = spider.appWithConfig(.{ .views_dir = null, .static_dir = null });
    _ = s.use(requirePublic)
        .post("/device/event", deviceEcho, .{ .public = true })
        .listen(.{ .port = port, .host = "127.0.0.1" }) catch |err| {
        std.log.err("large body app listen() failed: {s}", .{@errorName(err)});
    };
}

var large_body_port: ?u16 = null;
fn largeBodyAppPort(io: std.Io) !u16 {
    try app_once_mutex.lock(io);
    defer app_once_mutex.unlock(io);
    if (large_body_port) |p| return p;
    const port = try reserveEphemeralPort(io);
    (try std.Thread.spawn(.{}, runLargeBodyApp, .{port})).detach();
    try waitForPort(io, port);
    large_body_port = port;
    return port;
}

test "large body: route, headers and request id survive reading a 300 KB body" {
    var env = TestEnv.init();
    defer env.deinit();
    const io = env.io();
    const a = env.arena.allocator();
    const stream = try connectTo(io, try largeBodyAppPort(io));
    defer stream.close(io);

    const body = try a.alloc(u8, 300 * 1024);
    @memset(body, 'b');
    body[body.len - 1] = 'Z';
    const head = try std.fmt.allocPrint(a, "POST /device/event HTTP/1.1\r\nHost: x\r\nX-Device: gate-1\r\n" ++
        "X-Request-Id: device-req-42\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});
    try send(io, stream, head);
    try send(io, stream, body);

    const r = try readUntilClose(io, a, stream);
    try std.testing.expect(std.mem.startsWith(u8, r.bytes, "HTTP/1.1 200"));
    const expected = try std.fmt.allocPrint(a, "path=/device/event device=gate-1 type=application/json rid=device-req-42 len={d} last=Z", .{body.len});
    try std.testing.expect(std.mem.endsWith(u8, r.bytes, expected));
    try std.testing.expect(std.mem.indexOf(u8, r.bytes, "X-Request-Id: device-req-42") != null);
}

test "deadline: a slow but steady body is not cut" {
    var env = TestEnv.init();
    defer env.deinit();
    const io = env.io();
    const stream = try connectTo(io, try deadlineAppPort(io));
    defer stream.close(io);
    try send(io, stream, "POST /len HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: 8\r\n\r\n");
    // 8 bytes, one every 150 ms: 1.2 s in total, each gap below the 300 ms deadline.
    for (0..8) |_| {
        std.Io.sleep(io, .fromMilliseconds(150), .real) catch {};
        try send(io, stream, "x");
    }
    const r = try readUntilClose(io, env.arena.allocator(), stream);
    try std.testing.expect(std.mem.startsWith(u8, r.bytes, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.endsWith(u8, r.bytes, "\r\n\r\n8"));
}

test "deadline: a handler slower than every deadline still answers" {
    var env = TestEnv.init();
    defer env.deinit();
    const res = try request(env.io(), env.arena.allocator(), try deadlineAppPort(env.io()), "/slow", .{});
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("slow", res.body);
}

test "deadline: an idle keep-alive connection is closed after its response" {
    var env = TestEnv.init();
    defer env.deinit();
    const io = env.io();
    const stream = try connectTo(io, try deadlineAppPort(io));
    defer stream.close(io);
    try send(io, stream, "GET /fast HTTP/1.1\r\nHost: x\r\n\r\n");
    const r = try readUntilClose(io, env.arena.allocator(), stream);
    try std.testing.expect(r.closed_by_server);
    try std.testing.expect(std.mem.startsWith(u8, r.bytes, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.endsWith(u8, r.bytes, "fast"));
}

test "accept loop: running out of file descriptors does not stop the server" {
    var env = TestEnv.init();
    defer env.deinit();
    const io = env.io();
    const port = try reserveEphemeralPort(io);
    (try std.Thread.spawn(.{}, runPlainApp, .{port})).detach();
    try waitForPort(io, port);

    // Leave this process exactly one free descriptor, spend it on a client
    // socket: the server's accept() for that connection then fails with
    // EMFILE (ProcessFdQuotaExceeded).
    const saved = try std.posix.getrlimit(.NOFILE);
    const probe = std.c.open("/dev/null", .{});
    try std.testing.expect(probe >= 0);
    _ = std.c.close(probe);
    try std.posix.setrlimit(.NOFILE, .{ .cur = @intCast(probe + 48), .max = saved.max });
    var dummies: [64]std.c.fd_t = undefined;
    var n: usize = 0;
    while (n < dummies.len) : (n += 1) {
        const fd = std.c.open("/dev/null", .{});
        if (fd < 0) break;
        dummies[n] = fd;
    }
    n -= 1;
    _ = std.c.close(dummies[n]);
    const pending = connectTo(io, port);
    std.Io.sleep(io, .fromMilliseconds(300), .real) catch {};
    for (dummies[0..n]) |fd| _ = std.c.close(fd);
    try std.posix.setrlimit(.NOFILE, saved);

    const stream = try pending;
    defer stream.close(io);
    try send(io, stream, "GET /fast HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    const r = try readUntilClose(io, env.arena.allocator(), stream);
    try std.testing.expect(std.mem.startsWith(u8, r.bytes, "HTTP/1.1 200"));

    const res = try request(io, env.arena.allocator(), port, "/fast", .{});
    try std.testing.expectEqual(@as(u16, 200), res.status);
}

// ── SSE: a client that stops reading ────────────────────────────────────

const big_frame_len = 64 * 1024;
const big_frame: [big_frame_len]u8 = @splat('x');
const big_emits = 400; // ~25 MB: far more than the socket buffers of one client

fn sseJoinAll(sse: *spider.Sse) !void {
    try sse.join("all");
    sse.wait();
}

fn emitBig(c: *spider.Ctx) !spider.Response {
    c.sseHub().broadcastToChannel("all", &big_frame);
    return c.text("ok", .{});
}

fn runSseApp(port: u16) void {
    var s = spider.appWithConfig(.{ .views_dir = null, .static_dir = null, .stream_write_timeout_ms = 500 });
    s.sse("/events", sseJoinAll)
        .post("/emit", emitBig, .{})
        .listen(.{ .port = port, .host = "127.0.0.1" }) catch |err| {
        std.log.err("sse app listen() failed: {s}", .{@errorName(err)});
    };
}

fn countBytes(io: std.Io, stream: std.Io.net.Stream, total: *std.atomic.Value(usize)) void {
    var rbuf: [64 * 1024]u8 = undefined;
    var chunk: [64 * 1024]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    while (true) {
        const n = r.interface.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        _ = total.fetchAdd(n, .monotonic);
    }
}

fn emitter(io: std.Io, port: u16, done: *std.atomic.Value(usize)) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    for (0..big_emits) |_| {
        _ = arena.reset(.retain_capacity);
        _ = request(io, arena.allocator(), port, "/emit", .{ .method = "POST", .body = "" }) catch return;
        _ = done.fetchAdd(1, .monotonic);
    }
}

test "sse: a client that stops reading is dropped; the others keep receiving" {
    var env = TestEnv.init();
    defer env.deinit();
    const io = env.io();
    const port = try reserveEphemeralPort(io);
    (try std.Thread.spawn(.{}, runSseApp, .{port})).detach();
    try waitForPort(io, port);

    const stalled = try connectTo(io, port);
    defer stalled.close(io);
    try send(io, stalled, "GET /events HTTP/1.1\r\nHost: x\r\n\r\n");
    const reader = try connectTo(io, port);
    defer reader.close(io);
    try send(io, reader, "GET /events HTTP/1.1\r\nHost: x\r\n\r\n");
    var received: std.atomic.Value(usize) = .init(0);
    const counter = try std.Thread.spawn(.{}, countBytes, .{ io, reader, &received });
    // Stop the counter before `reader` is closed (it would read a closed fd).
    defer {
        _ = std.c.shutdown(reader.socket.handle, std.c.SHUT.RDWR);
        counter.join();
    }
    std.Io.sleep(io, .fromMilliseconds(300), .real) catch {};

    var emitted: std.atomic.Value(usize) = .init(0);
    const emitting = try std.Thread.spawn(.{}, emitter, .{ io, port, &emitted });

    // Every emit must complete and the reading client must get every frame,
    // however long the stalled client stays stuck.
    var waited: u32 = 0;
    while (waited < 20_000) : (waited += 100) {
        if (emitted.load(.monotonic) == big_emits and received.load(.monotonic) >= big_emits * big_frame_len) break;
        std.Io.sleep(io, .fromMilliseconds(100), .real) catch {};
    }
    if (emitted.load(.monotonic) != big_emits or received.load(.monotonic) < big_emits * big_frame_len) {
        emitting.detach(); // stuck on the server; can't be joined
        std.debug.print("\nemitted {d}/{d}, reader got {d} of {d} bytes\n", .{ emitted.load(.monotonic), big_emits, received.load(.monotonic), big_emits * big_frame_len });
        return error.TestUnexpectedResult;
    }
    emitting.join();

    // And the stalled one was closed by the server, so its EventSource
    // would reconnect instead of hanging on a dead stream.
    const r = try readUntilClose(io, env.arena.allocator(), stalled);
    try std.testing.expect(r.closed_by_server);
}

// ── Group parity, defaults, use(), route meta ──────────────────────────

const org_admin = "X-Test-Orgs: orgA=admin";

test "group defaults: routes inherit the group's org roles" {
    var env = TestEnv.init();
    defer env.deinit();
    try expectStatus(403, &env, "/g2/inherit/1", .{});
    try expectStatus(200, &env, "/g2/inherit/1", .{ .headers = &.{org_admin} });
}

test "group defaults: .public opts a route out" {
    var env = TestEnv.init();
    defer env.deinit();
    try expectStatus(200, &env, "/g2/open", .{});
}

test "group defaults: a route's own roles replace the group's" {
    var env = TestEnv.init();
    defer env.deinit();
    try expectStatus(403, &env, "/g2/staff/1", .{ .method = "POST", .headers = &.{org_admin} });
    try expectStatus(200, &env, "/g2/staff/1", .{ .method = "POST", .headers = &.{"X-Test-Roles: staff"} });
}

test "group: extractor handlers work (and inherit the defaults)" {
    var env = TestEnv.init();
    defer env.deinit();
    const port = try appPort(env.io());
    try expectStatus(403, &env, "/g2/typed/5", .{});
    const res = try request(env.io(), env.arena.allocator(), port, "/g2/typed/5", .{ .headers = &.{org_admin} });
    try std.testing.expectEqualStrings("typed:5", res.body);
    try expectStatus(400, &env, "/g2/typed/abc", .{ .headers = &.{org_admin} });
}

test "group: patch and head" {
    var env = TestEnv.init();
    defer env.deinit();
    try expectStatus(200, &env, "/g2/p/1", .{ .method = "PATCH", .headers = &.{org_admin} });
    try expectStatus(403, &env, "/g2/p/1", .{ .method = "PATCH" });
    try expectStatus(200, &env, "/g2/h", .{ .method = "HEAD", .headers = &.{org_admin} });
}

test "group use(): runs on every route of the group, after the RBAC check" {
    var env = TestEnv.init();
    defer env.deinit();
    const port = try appPort(env.io());
    const a = env.arena.allocator();
    const ok_res = try request(env.io(), a, port, "/g2/inherit/1", .{ .headers = &.{org_admin} });
    try std.testing.expectEqualStrings("g2", ok_res.header("X-Group").?);
    const open = try request(env.io(), a, port, "/g2/open", .{});
    try std.testing.expectEqualStrings("g2", open.header("X-Group").?);
    const denied = try request(env.io(), a, port, "/g2/inherit/1", .{});
    try std.testing.expectEqual(@as(u16, 403), denied.status);
    try std.testing.expect(denied.header("X-Group") == null); // the gate ran first
    const other = try request(env.io(), a, port, "/public/1", .{});
    try std.testing.expect(other.header("X-Group") == null); // not in the group
}

test "route meta reaches the handler (c.route())" {
    var env = TestEnv.init();
    defer env.deinit();
    const port = try appPort(env.io());
    const a = env.arena.allocator();
    const m = try request(env.io(), a, port, "/g2/meta", .{ .headers = &.{org_admin} });
    try std.testing.expectEqualStrings("public=false quiet_log=true allow_http=true org_roles=1", m.body);
    const p = try request(env.io(), a, port, "/meta/public", .{});
    try std.testing.expectEqualStrings("public=true quiet_log=false allow_http=false org_roles=0", p.body);
}

// ── mountFeatures on a real server: boot() at listen, jobs run ─────────

var e2e_booted: std.atomic.Value(bool) = .init(false);
var e2e_ticks: std.atomic.Value(u32) = .init(0);

fn e2eTick(_: *spider.Hub) void {
    _ = e2e_ticks.fetchAdd(1, .monotonic);
}

const e2e_features = struct {
    pub const widgets = struct {
        pub const routes = struct {
            pub fn build() spider.Group {
                var g = spider.Group.init("/widgets");
                _ = g.get("/:id", typed_w, .{});
                return g;
            }
        };
        pub const jobs = .{spider.every(100, e2eTick)};
        pub fn boot(b: spider.Boot) !void {
            _ = b;
            e2e_booted.store(true, .release);
        }
    };
};

fn typed_w(id: spider.Path(i64, "id"), c: *spider.Ctx) !spider.Response {
    return c.text(try std.fmt.allocPrint(c.arena, "widget:{d}", .{id.value}), .{});
}

fn runFeaturesApp(port: u16) void {
    var s = spider.appWithConfig(.{ .views_dir = null, .static_dir = null });
    s.mountFeatures(e2e_features).listen(.{ .port = port, .host = "127.0.0.1" }) catch |err| {
        std.log.err("features app listen() failed: {s}", .{@errorName(err)});
    };
}

test "mountFeatures: routes served, boot() ran before serving, jobs tick" {
    var env = TestEnv.init();
    defer env.deinit();
    const io = env.io();
    const port = try reserveEphemeralPort(io);
    (try std.Thread.spawn(.{}, runFeaturesApp, .{port})).detach();
    try waitForPort(io, port);
    try std.testing.expect(e2e_booted.load(.acquire));
    const res = try request(io, env.arena.allocator(), port, "/widgets/9", .{});
    try std.testing.expectEqualStrings("widget:9", res.body);
    std.Io.sleep(io, .fromMilliseconds(600), .real) catch {};
    try std.testing.expect(e2e_ticks.load(.monotonic) >= 2);
}

// ── spider.errorHandler / forceHttps / varyHtmx ────────────────────────

fn eForbidden(_: *spider.Ctx) !spider.Response {
    return error.Forbidden;
}
fn eBoom(_: *spider.Ctx) !spider.Response {
    return error.Boom;
}
fn eUnauth(_: *spider.Ctx) !spider.Response {
    return error.Unauthorized;
}
fn eBad(c: *spider.Ctx) !spider.Response {
    c.setErrorDetail("bad name");
    return error.MissingField;
}
fn eConflict(_: *spider.Ctx) !spider.Response {
    return error.UniqueViolation;
}
fn htmlPage(c: *spider.Ctx) !spider.Response {
    return c.html("<p>x</p>", .{});
}

fn runPolicyApp(port: u16) void {
    var s = spider.appWithConfig(.{ .views_dir = null, .static_dir = null });
    s.use(spider.forceHttps(.{ .default_base_url = "https://example.test", .allow_http_paths = &.{ "/legacy*", "/exact" } }))
        .use(spider.varyHtmx)
        .get("/e/forbidden", eForbidden, .{})
        .get("/e/boom", eBoom, .{})
        .get("/e/unauth", eUnauth, .{})
        .get("/e/bad", eBad, .{})
        .get("/e/conflict", eConflict, .{})
        .get("/e/html", htmlPage, .{})
        .get("/e/text", fast, .{})
        .get("/exact", fast, .{})
        .get("/device", fast, .{ .allow_http = true })
        .onError(spider.errorHandler(.{
            .unauthorized_redirect = "/login",
            .json_key = "err",
            .toast_event = "app:toast",
            .messages = .{ .forbidden = "Sem permissão." },
        }))
        .listen(.{ .port = port, .host = "127.0.0.1" }) catch |err| {
        std.log.err("policy app listen() failed: {s}", .{@errorName(err)});
    };
}

var policy_port: ?u16 = null;
fn policyAppPort(io: std.Io) !u16 {
    try app_once_mutex.lock(io);
    defer app_once_mutex.unlock(io);
    if (policy_port) |p| return p;
    const port = try reserveEphemeralPort(io);
    (try std.Thread.spawn(.{}, runPolicyApp, .{port})).detach();
    try waitForPort(io, port);
    policy_port = port;
    return port;
}

const json_accept = "Accept: application/json";
const htmx = "HX-Request: true";

test "errorHandler: JSON callers get { <json_key>, request_id }" {
    var env = TestEnv.init();
    defer env.deinit();
    const io = env.io();
    const port = try policyAppPort(io);
    const a = env.arena.allocator();
    const r = try request(io, a, port, "/e/forbidden", .{ .headers = &.{json_accept} });
    try std.testing.expectEqual(@as(u16, 403), r.status);
    const rid = r.header("X-Request-Id").?;
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{{\"err\":\"Sem permissão.\",\"request_id\":\"{s}\"}}", .{rid}), r.body);
    try std.testing.expectEqualStrings("application/json", r.header("Content-Type").?);
    const c = try request(io, a, port, "/e/conflict", .{ .headers = &.{json_accept} });
    try std.testing.expectEqual(@as(u16, 409), c.status);
}

test "errorHandler: htmx gets the status, no swap, and a toast event" {
    var env = TestEnv.init();
    defer env.deinit();
    const io = env.io();
    const port = try policyAppPort(io);
    const a = env.arena.allocator();
    const r = try request(io, a, port, "/e/forbidden", .{ .headers = &.{htmx} });
    try std.testing.expectEqual(@as(u16, 403), r.status);
    try std.testing.expectEqualStrings("none", r.header("HX-Reswap").?);
    try std.testing.expectEqualStrings("{\"app:toast\":{\"message\":\"Sem permiss\\u00e3o.\",\"type\":\"warning\"}}", r.header("HX-Trigger").?);
    try std.testing.expectEqualStrings("", r.body);
    const b = try request(io, a, port, "/e/boom", .{ .headers = &.{htmx} });
    try std.testing.expectEqual(@as(u16, 500), b.status);
    const rid = b.header("X-Request-Id").?;
    const want = try std.fmt.allocPrint(a, "{{\"app:toast\":{{\"message\":\"Unexpected error. Try again (ref. {s}).\",\"type\":\"error\"}}}}", .{rid});
    try std.testing.expectEqualStrings(want, b.header("HX-Trigger").?);
}

test "errorHandler: pages get text; 400 uses the error detail; Unauthorized redirects" {
    var env = TestEnv.init();
    defer env.deinit();
    const io = env.io();
    const port = try policyAppPort(io);
    const a = env.arena.allocator();
    const f = try request(io, a, port, "/e/forbidden", .{});
    try std.testing.expectEqual(@as(u16, 403), f.status);
    try std.testing.expectEqualStrings("Sem permissão.", f.body);
    const bad = try request(io, a, port, "/e/bad", .{});
    try std.testing.expectEqual(@as(u16, 400), bad.status);
    try std.testing.expectEqualStrings("bad name", bad.body);
    for ([_][]const []const u8{ &.{}, &.{json_accept}, &.{htmx} }) |hdrs| {
        const u = try request(io, a, port, "/e/unauth", .{ .headers = hdrs });
        try std.testing.expectEqual(@as(u16, 302), u.status);
        try std.testing.expectEqualStrings("/login", u.header("Location").?);
    }
}

fn runJsonApp(port: u16) void {
    var s = spider.appWithConfig(.{ .views_dir = null, .static_dir = null });
    s.get("/e/forbidden", eForbidden, .{})
        .get("/e/boom", eBoom, .{})
        .onError(spider.errorHandler(.{ .always_json = true }))
        .listen(.{ .port = port, .host = "127.0.0.1" }) catch |err| {
        std.log.err("json app listen() failed: {s}", .{@errorName(err)});
    };
}

var json_port: ?u16 = null;
fn jsonAppPort(io: std.Io) !u16 {
    try app_once_mutex.lock(io);
    defer app_once_mutex.unlock(io);
    if (json_port) |p| return p;
    const port = try reserveEphemeralPort(io);
    (try std.Thread.spawn(.{}, runJsonApp, .{port})).detach();
    try waitForPort(io, port);
    json_port = port;
    return port;
}

test "errorHandler: always_json answers JSON without an Accept header, htmx included" {
    var env = TestEnv.init();
    defer env.deinit();
    const io = env.io();
    const port = try jsonAppPort(io);
    const a = env.arena.allocator();
    for ([_][]const []const u8{ &.{}, &.{htmx} }) |hdrs| {
        const r = try request(io, a, port, "/e/forbidden", .{ .headers = hdrs });
        try std.testing.expectEqual(@as(u16, 403), r.status);
        try std.testing.expectEqualStrings("application/json", r.header("Content-Type").?);
        const rid = r.header("X-Request-Id").?;
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{{\"error\":\"You don't have permission to do this.\",\"request_id\":\"{s}\"}}", .{rid}), r.body);
    }
    const b = try request(io, a, port, "/e/boom", .{});
    try std.testing.expectEqual(@as(u16, 500), b.status);
    try std.testing.expectEqualStrings("application/json", b.header("Content-Type").?);
}

test "forceHttps: redirects plain HTTP, except .allow_http routes and allow_http_paths" {
    var env = TestEnv.init();
    defer env.deinit();
    const io = env.io();
    const port = try policyAppPort(io);
    const a = env.arena.allocator();
    const http = "X-Forwarded-Proto: http";
    const r = try request(io, a, port, "/e/text?x=1", .{ .headers = &.{http} });
    try std.testing.expectEqual(@as(u16, 302), r.status);
    try std.testing.expectEqualStrings("https://example.test/e/text?x=1", r.header("Location").?);
    try std.testing.expectEqual(@as(u16, 200), (try request(io, a, port, "/e/text", .{})).status); // no header: HTTPS assumed
    try std.testing.expectEqual(@as(u16, 200), (try request(io, a, port, "/e/text", .{ .headers = &.{"X-Forwarded-Proto: https"} })).status);
    try std.testing.expectEqual(@as(u16, 200), (try request(io, a, port, "/device", .{ .headers = &.{http} })).status);
    try std.testing.expectEqual(@as(u16, 200), (try request(io, a, port, "/exact", .{ .headers = &.{http} })).status);
    try std.testing.expectEqual(@as(u16, 302), (try request(io, a, port, "/exact?q=1", .{ .headers = &.{http} })).status); // exact means exact
    try std.testing.expectEqual(@as(u16, 404), (try request(io, a, port, "/legacy/whatever", .{ .headers = &.{http} })).status); // prefix, no route
}

test "varyHtmx: Vary: HX-Request on HTML only" {
    var env = TestEnv.init();
    defer env.deinit();
    const io = env.io();
    const port = try policyAppPort(io);
    const a = env.arena.allocator();
    try std.testing.expectEqualStrings("HX-Request", (try request(io, a, port, "/e/html", .{})).header("Vary").?);
    try std.testing.expect((try request(io, a, port, "/e/text", .{})).header("Vary") == null);
}

fn runUndeclaredApp(port: u16) void {
    var s = spider.appWithConfig(.{ .views_dir = null, .static_dir = null });
    s.get("/forgot", ok, .{})
        .listen(.{ .port = port, .host = "127.0.0.1" }) catch |err| {
        std.log.err("undeclared app listen() failed: {s}", .{@errorName(err)});
    };
}

test "require_route_access: the same app boots without the flag, and refuses to with it" {
    var env = TestEnv.init();
    defer env.deinit();
    const io = env.io();
    const a = env.arena.allocator();

    // Without the flag (the default): serves the route that declares nothing.
    const port = try reserveEphemeralPort(io);
    (try std.Thread.spawn(.{}, runUndeclaredApp, .{port})).detach();
    try waitForPort(io, port);
    try std.testing.expectEqual(@as(u16, 200), (try request(io, a, port, "/forgot", .{})).status);

    // With it: listen() returns the error before binding; the port stays free.
    var s = spider.appWithConfig(.{ .views_dir = null, .static_dir = null, .require_route_access = true });
    _ = s.get("/forgot", ok, .{});
    const port2 = try reserveEphemeralPort(io);
    try std.testing.expectError(error.RouteAccessUndeclared, s.listen(.{ .port = port2, .host = "127.0.0.1" }));
    try std.testing.expectError(error.ConnectionRefused, request(io, a, port2, "/forgot", .{}));
}

test ".authenticated: 401 without an identity, 200 with one; roles and .public still replace it" {
    var env = TestEnv.init();
    defer env.deinit();
    try expectStatus(401, &env, "/logged/me", .{});
    try expectStatus(200, &env, "/logged/me", .{ .headers = &.{"X-Test-Sub: user-1"} });
    try expectStatus(403, &env, "/logged/admin", .{ .headers = &.{"X-Test-Sub: user-1"} });
    try expectStatus(200, &env, "/logged/admin", .{ .headers = &.{ "X-Test-Sub: user-1", "X-Test-Roles: admin" } });
    try expectStatus(200, &env, "/logged/open", .{});
}
