const std = @import("std");
const context_mod = @import("context.zig");
const Ctx = context_mod.Ctx;
const Response = context_mod.Response;
const app_mod = @import("app.zig");
const Server = app_mod.Server;
const extractors = @import("extractors.zig");
const Path = extractors.Path;
const Form = extractors.Form;

const NoDeco = struct {};

// Drives a registered route the same way a real request would: resolves the
// route through the (public) router, builds a Ctx the way workerLoop does
// (including `_decorations`, matching app.zig's `@sizeOf(T) == 0` check),
// and invokes the resulting Handler — exercising the real Server.get/post
// dispatch decision (Handler passthrough / buildAutoWrapper / buildWrapper),
// not a reimplementation of it.
fn dispatch(
    comptime T: type,
    s: *Server(T),
    method: std.http.Method,
    path: []const u8,
    alc: std.mem.Allocator,
    body: ?[]const u8,
) !Response {
    const match = (try s.router.match(method, path, alc)).?;
    var ctx = Ctx{
        .request = undefined,
        .arena = alc,
        .params = match.params,
        .body = body,
        ._decorations = if (@sizeOf(T) == 0) null else @as(*const anyopaque, @ptrCast(&s.decorations)),
    };
    return match.handler(&ctx);
}

/// Like dispatch(), but for handlers expected to FAIL: returns the error
/// and the detail the extractor attached (Ctx.errorDetail()).
fn dispatchErr(
    comptime T: type,
    s: *Server(T),
    method: std.http.Method,
    path: []const u8,
    alc: std.mem.Allocator,
    body: ?[]const u8,
) !struct { err: anyerror, detail: ?[]const u8 } {
    const match = (try s.router.match(method, path, alc)).?;
    var ctx = Ctx{
        .request = undefined,
        .arena = alc,
        .params = match.params,
        .body = body,
        ._decorations = if (@sizeOf(T) == 0) null else @as(*const anyopaque, @ptrCast(&s.decorations)),
    };
    _ = match.handler(&ctx) catch |err| return .{ .err = err, .detail = ctx.errorDetail() };
    return error.TestExpectedError;
}

const UpdateForm = struct { name: []const u8 };

fn getById(id: Path(i64, "id"), c: *Ctx) !Response {
    return c.text(try std.fmt.allocPrint(c.arena, "{d}", .{id.value}), .{});
}

fn formOnly(form: Form(UpdateForm), c: *Ctx) !Response {
    return c.text(form.value.name, .{});
}

fn comboCtxFirst(c: *Ctx, id: Path(i64, "id"), form: Form(UpdateForm)) !Response {
    return c.text(try std.fmt.allocPrint(c.arena, "{d}:{s}", .{ id.value, form.value.name }), .{});
}

fn comboCtxLast(id: Path(i64, "id"), form: Form(UpdateForm), c: *Ctx) !Response {
    return c.text(try std.fmt.allocPrint(c.arena, "{d}:{s}", .{ id.value, form.value.name }), .{});
}

fn oldStyle(c: *Ctx) !Response {
    return c.text("old", .{});
}

const Deco = struct { greeting: []const u8 };

fn decoHandler(c: *Ctx, greeting: []const u8) !Response {
    return c.text(greeting, .{});
}

test "Path extractor: success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.get("/items/:id", getById, .{});

    const resp = try dispatch(NoDeco, &s, .GET, "/items/42", alc, null);
    try std.testing.expectEqual(std.http.Status.ok, resp.status);
    try std.testing.expectEqualStrings("42", resp.body.?);
}

test "Path extractor: invalid int -> error.InvalidPathParam (400) with detail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.get("/items/:id", getById, .{});

    const r = try dispatchErr(NoDeco, &s, .GET, "/items/abc", alc, null);
    try std.testing.expectEqual(error.InvalidPathParam, r.err);
    try std.testing.expectEqualStrings("invalid path param: id", r.detail.?);
    try std.testing.expectEqual(std.http.Status.bad_request, context_mod.statusForError(r.err));
}

test "Path extractor: missing param -> error.MissingPathParam (400) with detail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var s = Server(NoDeco).init();
    defer s.deinit();
    // Route deliberately has no `:id` segment, so ctx.params won't have it —
    // exercises the extractor's own "missing" branch.
    _ = s.get("/items", getById, .{});

    const r = try dispatchErr(NoDeco, &s, .GET, "/items", alc, null);
    try std.testing.expectEqual(error.MissingPathParam, r.err);
    try std.testing.expectEqualStrings("missing path param: id", r.detail.?);
    try std.testing.expectEqual(std.http.Status.bad_request, context_mod.statusForError(r.err));
}

test "Form extractor: success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.post("/form", formOnly, .{});

    const resp = try dispatch(NoDeco, &s, .POST, "/form", alc, "name=hello");
    try std.testing.expectEqual(std.http.Status.ok, resp.status);
    try std.testing.expectEqualStrings("hello", resp.body.?);
}

test "Form extractor: parse failure -> the parse error (400) with detail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.post("/form", formOnly, .{});

    // No body at all -> Ctx.parseForm returns error.BodyEmpty.
    const r = try dispatchErr(NoDeco, &s, .POST, "/form", alc, null);
    try std.testing.expectEqual(error.BodyEmpty, r.err);
    try std.testing.expectEqualStrings("invalid form body", r.detail.?);
    try std.testing.expectEqual(std.http.Status.bad_request, context_mod.statusForError(r.err));
}

test "statusForError: defaults" {
    const sfe = context_mod.statusForError;
    try std.testing.expectEqual(std.http.Status.not_found, sfe(error.NotFound));
    try std.testing.expectEqual(std.http.Status.forbidden, sfe(error.Forbidden));
    try std.testing.expectEqual(std.http.Status.unauthorized, sfe(error.Unauthorized));
    try std.testing.expectEqual(std.http.Status.bad_request, sfe(error.MissingField));
    try std.testing.expectEqual(std.http.Status.bad_request, sfe(error.SyntaxError));
    // Generic "the request is wrong": app code rejecting input it validated
    // itself (with c.setErrorDetail for the message).
    try std.testing.expectEqual(std.http.Status.bad_request, sfe(error.BadRequest));
    try std.testing.expectEqual(std.http.Status.internal_server_error, sfe(error.PG));
    try std.testing.expectEqual(std.http.Status.conflict, sfe(error.UniqueViolation));
    try std.testing.expectEqual(std.http.Status.conflict, sfe(error.ForeignKeyViolation));
    try std.testing.expectEqual(std.http.Status.bad_request, sfe(error.InvalidTextRepresentation));
    try std.testing.expectEqual(std.http.Status.bad_request, sfe(error.InvalidUUID));
    try std.testing.expectEqual(std.http.Status.unprocessable_entity, sfe(error.RaisedException));
    try std.testing.expectEqual(std.http.Status.service_unavailable, sfe(error.SerializationFailure));
    try std.testing.expectEqual(std.http.Status.internal_server_error, sfe(error.DivisionByZero));
    try std.testing.expectEqual(std.http.Status.internal_server_error, sfe(error.ColumnMissing));
    try std.testing.expectEqual(std.http.Status.internal_server_error, sfe(error.OutOfMemory));
}

test "combo: Path + Form + *Ctx, *Ctx first — order does not matter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.post("/items/:id", comboCtxFirst, .{});

    const resp = try dispatch(NoDeco, &s, .POST, "/items/7", alc, "name=zig");
    try std.testing.expectEqual(std.http.Status.ok, resp.status);
    try std.testing.expectEqualStrings("7:zig", resp.body.?);
}

test "combo: Path + Form + *Ctx, *Ctx last — order does not matter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.post("/items/:id", comboCtxLast, .{});

    const resp = try dispatch(NoDeco, &s, .POST, "/items/7", alc, "name=zig");
    try std.testing.expectEqual(std.http.Status.ok, resp.status);
    try std.testing.expectEqualStrings("7:zig", resp.body.?);
}

test "old-style fn(*Ctx) handler is unaffected by the extractor dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.get("/old", oldStyle, .{});

    const resp = try dispatch(NoDeco, &s, .GET, "/old", alc, null);
    try std.testing.expectEqual(std.http.Status.ok, resp.status);
    try std.testing.expectEqualStrings("old", resp.body.?);
}

test "loose-type decoration handler (buildWrapper) is unaffected by the extractor dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var s = Server(Deco).init();
    defer s.deinit();
    s.decorations = .{ .greeting = "hi-deco" };
    _ = s.get("/deco", decoHandler, .{});

    const resp = try dispatch(Deco, &s, .GET, "/deco", alc, null);
    try std.testing.expectEqual(std.http.Status.ok, resp.status);
    try std.testing.expectEqualStrings("hi-deco", resp.body.?);
}

// ── mountFeatures / mountFeature ─────────────────────────────────────────

const Group = @import("../routing/group.zig").Group;
const Hub = @import("../ws/hub.zig").Hub;

fn featOk(c: *Ctx) anyerror!Response {
    return c.text("feat", .{});
}

fn featTick(_: *Hub) void {}

var feat_booted: bool = false;

const feats = struct {
    pub const alpha = struct {
        pub const routes = struct {
            pub fn build() Group {
                var g = Group.init("/alpha");
                _ = g.get("", featOk, .{});
                return g;
            }
            pub fn buildWebhook() Group {
                var g = Group.init("/alpha-hook");
                _ = g.post("", featOk, .{ .public = true });
                return g;
            }
            // Not mounted: takes a parameter / isn't a function.
            pub fn helper(x: u8) u8 {
                return x;
            }
            pub const not_a_fn = 3;
        };
        pub const jobs = .{app_mod.every(60_000, featTick)};
        pub fn boot(_: app_mod.Boot) !void {
            feat_booted = true;
        }
    };
    pub const beta = struct {}; // a feature with nothing to register
    pub const constant = 42; // not a namespace: skipped
};

test "mountFeatures: mounts routes.*() groups, registers jobs and boot hooks" {
    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.mountFeatures(feats);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try s.router.match(.GET, "/alpha", a)) != null);
    const hook = (try s.router.match(.POST, "/alpha-hook", a)).?;
    try std.testing.expect(hook.meta.public);
    try std.testing.expectEqual(@as(usize, 1), s.interval_threads.items.len);
    try std.testing.expectEqual(@as(u64, 60_000), s.interval_threads.items[0].ms);
    try std.testing.expectEqual(@as(usize, 1), s.boot_hooks.items.len);
    try std.testing.expect(!feat_booted); // boot runs in listen(), not at registration
    try s.boot_hooks.items[0](.{ .allocator = std.testing.allocator, .io = undefined });
    try std.testing.expect(feat_booted);
}

test "mountFeature: one feature at a time" {
    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.mountFeature(feats.beta).mountFeature(feats.alpha);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try s.router.match(.GET, "/alpha", arena.allocator())) != null);
}

test "writeRoutes: sorted table with access and flags; duplicates counted" {
    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s
        .get("/b", featOk, .{ .org_roles = &.{ "admin", "sindico" } })
        .get("/a", featOk, .{ .public = true, .quiet_log = true, .allow_http = true })
        .post("/a", featOk, .{})
        .get("/c/:id", featOk, .{ .roles = &.{"staff"} })
        .get("/b", featOk, .{ .org_roles = &.{"admin"} }); // registered twice
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.writeRoutes(&w);
    const out = w.buffered();
    const expected =
        "GET     /a                                               public  quiet_log  allow_http\n" ++
        "POST    /a                                               -\n" ++
        "GET     /b                                               org:admin\n" ++
        "GET     /c/:id                                           roles:staff\n" ++
        "4 routes, 1 registered twice (see the warnings above)\n";
    try std.testing.expectEqualStrings(expected, out);
}

test "writeRoutes: background jobs are listed, shortest interval first" {
    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.get("/a", featOk, .{}).sseInterval(60_000, featTick).mountFeature(feats.alpha).sseInterval(5000, featTick);
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.writeRoutes(&w);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "3 background jobs, every: 5000ms 60000ms 60000ms\n"));
}

test "Group: a Handler only known at runtime is accepted (e.g. keycloak.loginHandler())" {
    var runtime_handler: @import("../routing/router.zig").Handler = featOk;
    _ = &runtime_handler;
    var g = Group.init("/rt");
    _ = g.get("/h", runtime_handler, .{ .public = true });
    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.mount(g);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = (try s.router.match(.GET, "/rt/h", arena.allocator())).?;
    try std.testing.expect(m.meta.public);
}

const Sse = @import("../ws/sse.zig").Sse;
const NextFn = context_mod.NextFn;
fn featStream(_: *Sse) anyerror!void {}
fn plainMw(c: *Ctx, next: NextFn) anyerror!Response {
    return next(c);
}
fn sessionMw(c: *Ctx, next: NextFn) anyerror!Response {
    return next(c);
}

test "require_route_access: a route without declared access fails the boot check, naming it" {
    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s
        .get("/open", featOk, .{ .public = true })
        .get("/staff", featOk, .{ .roles = &.{"staff"} })
        .get("/forgot", featOk, .{})
        .requireRouteAccess();
    try std.testing.expectError(error.RouteAccessUndeclared, s.checkRouteAccess());
}

test "require_route_access: listen() refuses to start (before binding any port)" {
    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.get("/forgot", featOk, .{}).requireRouteAccess();
    // Port 1 can't be bound by a test: reaching bind() would fail differently.
    try std.testing.expectError(error.RouteAccessUndeclared, s.listen(.{ .port = 1, .host = "127.0.0.1" }));
}

test "require_route_access: off by default, so existing apps with undeclared routes still boot" {
    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.get("/forgot", featOk, .{});
    try std.testing.expect(!s.config.require_route_access);
    try s.checkRouteAccess();
}

test "require_route_access: passes when every route declares access (group defaults count)" {
    var g = Group.init("/g");
    _ = g
        .defaults(.{ .org_roles = &.{"admin"} })
        .get("/a", featOk, .{})
        .sseWith("/events", featStream, .{})
        .get("/b", featOk, .{ .public = true });
    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.mount(g).sseWith("/feed", featStream, .{ .roles = &.{"staff"} }).requireRouteAccess();
    try s.checkRouteAccess();
}

test "require_route_access: plain sse() routes declare nothing" {
    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.sse("/events", featStream).requireRouteAccess();
    try std.testing.expectError(error.RouteAccessUndeclared, s.checkRouteAccess());
}

test "built-ins: /up and /_spider/health are public; dev-only /_spider/reload declares nothing but passes the check" {
    var s = app_mod.appWithConfig(.{ .views_dir = null, .static_dir = null, .env = .development });
    defer s.deinit();
    _ = s.requireRouteAccess();
    try s.checkRouteAccess();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "/up", "/_spider/health" }) |p| {
        const m = (try s.router.match(.GET, p, arena.allocator())).?;
        try std.testing.expect(m.meta.public and m.meta.quiet_log);
    }
    const reload = (try s.router.match(.GET, "/_spider/reload", arena.allocator())).?;
    try std.testing.expect(!reload.meta.declaresAccess());
}

test "hasAuth: only a marked middleware (use or useAt) counts" {
    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.use(plainMw);
    try std.testing.expect(!s.hasAuth());
    @import("../modules/auth_marker.zig").mark(sessionMw);
    _ = s.useAt("/app", sessionMw);
    try std.testing.expect(s.hasAuth());
}

test "writeRoutesJson: auth flag, routes with access and flags, jobs" {
    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s
        .get("/b", featOk, .{ .org_roles = &.{"admin"}, .roles = &.{"staff"} })
        .get("/a", featOk, .{ .public = true, .quiet_log = true })
        .get("/c", featOk, .{ .policy = spider_policy("post_owner") })
        .sseInterval(5000, featTick);
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.writeRoutesJson(&w);
    try std.testing.expectEqualStrings(
        "{\"auth\":false,\"routes\":[" ++
            "{\"method\":\"GET\",\"path\":\"/a\",\"access\":\"public\",\"public\":true,\"authenticated\":false,\"roles\":[],\"org_roles\":[],\"quiet_log\":true,\"allow_http\":false,\"policy\":null}," ++
            "{\"method\":\"GET\",\"path\":\"/b\",\"access\":\"org:admin roles:staff\",\"public\":false,\"authenticated\":false,\"roles\":[\"staff\"],\"org_roles\":[\"admin\"],\"quiet_log\":false,\"allow_http\":false,\"policy\":null}," ++
            "{\"method\":\"GET\",\"path\":\"/c\",\"access\":\"policy:post_owner\",\"public\":false,\"authenticated\":false,\"roles\":[],\"org_roles\":[],\"quiet_log\":false,\"allow_http\":false,\"policy\":\"post_owner\"}" ++
            "],\"jobs_ms\":[5000],\"duplicates\":0}\n",
        w.buffered(),
    );
}

test "Group.sseWith: inherits the group's defaults() like any route" {
    var g = Group.init("/live");
    _ = g.defaults(.{ .org_roles = &.{"admin"} }).sseWith("/events", featStream, .{});
    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.mount(g);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = (try s.router.match(.GET, "/live/events", arena.allocator())).?;
    try std.testing.expectEqual(@as(usize, 1), m.meta.org_roles.len);
    try std.testing.expectEqual(@as(usize, 1), m.middlewares.len);
}

fn featPolicyCheck(c: *Ctx) bool {
    _ = c;
    return true;
}
fn spider_policy(comptime name: []const u8) @import("../modules/rbac.zig").Policy {
    return comptime @import("../modules/rbac.zig").policy(name, featPolicyCheck);
}

test "Group: a route's .policy replaces the group's defaults() like .roles does, and counts as declared access" {
    var g = Group.init("/posts");
    _ = g
        .defaults(.{ .roles = &.{"staff"} })
        .get("/all", featOk, .{})
        .post("/:id/edit", featOk, .{ .policy = spider_policy("post_owner") })
        .post("/:id/pin", featOk, .{ .roles = &.{"staff"}, .policy = spider_policy("post_owner") });
    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.mount(g).requireRouteAccess();
    try s.checkRouteAccess();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edit = (try s.router.match(.POST, "/posts/1/edit", arena.allocator())).?;
    try std.testing.expectEqualStrings("post_owner", edit.meta.policy.?);
    try std.testing.expectEqual(@as(usize, 0), edit.meta.roles.len);
    try std.testing.expectEqual(@as(usize, 1), edit.middlewares.len);
    const pin = (try s.router.match(.POST, "/posts/1/pin", arena.allocator())).?;
    try std.testing.expectEqual(@as(usize, 2), pin.middlewares.len);
    const list = (try s.router.match(.GET, "/posts/all", arena.allocator())).?;
    try std.testing.expect(list.meta.policy == null);
    try std.testing.expectEqual(@as(usize, 1), list.meta.roles.len);
}

// --- spider.Loaded(T): the resource a resourcePolicy loaded ------------------

const rbac_mod = @import("../modules/rbac.zig");
const Loaded = extractors.Loaded;
const Note = struct { id: u32, owner: []const u8, text: []const u8 };

fn loadNote(c: *Ctx) !?Note {
    const id = std.fmt.parseInt(u32, c.params.get("id") orelse return null, 10) catch return null;
    return if (id == 7) .{ .id = 7, .owner = "1", .text = "hello" } else null;
}
fn ownsNote(c: *Ctx, n: *const Note) bool {
    return std.mem.eql(u8, n.owner, c.userId() orelse "");
}
fn showNote(note: Loaded(Note), c: *Ctx) !Response {
    return c.text(try std.fmt.allocPrint(c.arena, "{d}:{s}", .{ note.value.id, note.value.text }), .{});
}

/// dispatch() through the route's own middlewares (its RBAC / policy).
fn dispatchChain(s: *Server(NoDeco), method: std.http.Method, path: []const u8, alc: std.mem.Allocator, user: ?[]const u8) !Response {
    const match = (try s.router.match(method, path, alc)).?;
    var ctx = Ctx{ .request = undefined, .arena = alc, .params = match.params, .body = null, ._route = match.meta };
    if (user) |u| try ctx.setUser(.{ .id = u });
    try std.testing.expectEqual(@as(usize, 1), match.middlewares.len);
    return match.middlewares[0](&ctx, match.handler);
}

test "Loaded extractor: the handler gets the resource the route's resourcePolicy loaded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.get("/notes/:id", showNote, .{ .policy = rbac_mod.resourcePolicy("note_owner", Note, .{ .load = loadNote, .check = ownsNote }) });
    const resp = try dispatchChain(&s, .GET, "/notes/7", arena.allocator(), "1");
    try std.testing.expectEqualStrings("7:hello", resp.body.?);
    try std.testing.expectError(error.Forbidden, dispatchChain(&s, .GET, "/notes/7", arena.allocator(), "2"));
    try std.testing.expectError(error.NotFound, dispatchChain(&s, .GET, "/notes/8", arena.allocator(), "1"));
}

test "Loaded extractor: without a resourcePolicy for that type -> error.ResourceNotLoaded (500) with detail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.get("/notes/:id", showNote, .{});
    const r = try dispatchErr(NoDeco, &s, .GET, "/notes/7", arena.allocator(), null);
    try std.testing.expectEqual(error.ResourceNotLoaded, r.err);
    try std.testing.expect(std.mem.indexOf(u8, r.detail.?, "Note") != null);
    try std.testing.expectEqual(std.http.Status.internal_server_error, context_mod.statusForError(r.err));
}
