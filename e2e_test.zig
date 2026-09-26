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

fn ok(c: *spider.Ctx) !spider.Response {
    const id = c.params.get("id") orelse "-";
    return c.text(try std.fmt.allocPrint(c.arena, "ok:{s}", .{id}), .{});
}

fn errorHandler(c: *spider.Ctx, err: anyerror) !spider.Response {
    return switch (err) {
        error.Forbidden => c.text("forbidden", .{ .status = .forbidden }),
        else => c.text(@errorName(err), .{ .status = .internal_server_error }),
    };
}

const admin = &[_][]const u8{"admin"};

fn runApp(port: u16) void {
    var s = spider.app(.{});

    var g = spider.Group.init("/g");
    _ = g
        .get("/things", ok, .{ .org_roles = admin })
        .get("/things/:id", ok, .{ .org_roles = admin })
        .post("/things/:id/edit", ok, .{ .roles = admin })
        .get("/open/:id", ok, .{});

    s
        .use(fakeAuth)
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
        .mount(g)
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
