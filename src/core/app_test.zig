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
