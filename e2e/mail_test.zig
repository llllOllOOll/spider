// End-to-end tests for spider.mail: an app whose handlers send mail through
// each provider transport, against a fake provider running in-process.
//
// The fake speaks the three provider APIs (Brevo, Resend, Postmark): it
// checks the credentials the way the real ones do, records what it was
// sent, and answers with the provider's success or error shape. So the
// whole path runs for real: handler -> Mailer -> payload -> HTTP -> status
// mapping -> receipt.

const std = @import("std");
const spider = @import("spider");
const h = @import("../e2e_test.zig");

const mail = spider.mail;

const good_key = "good-key";

var provider_port: u16 = 0;
var app_port: u16 = 0;
var start_mutex: std.Io.Mutex = .init;
var started = false;
var outbox: mail.Outbox = undefined;

// ── fake provider ───────────────────────────────────────────────────────

/// The last request the fake provider received.
const Captured = struct {
    lock: std.atomic.Mutex = .unlocked,
    calls: u32 = 0,
    path_buf: [64]u8 = undefined,
    path_len: usize = 0,
    body_buf: [8192]u8 = undefined,
    body_len: usize = 0,
    content_type_buf: [128]u8 = undefined,
    content_type_len: usize = 0,

    fn acquire(self: *Captured) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn record(self: *Captured, path: []const u8, body: []const u8, content_type: []const u8) void {
        self.acquire();
        defer self.lock.unlock();
        self.calls += 1;
        self.path_len = copyInto(&self.path_buf, path);
        self.body_len = copyInto(&self.body_buf, body);
        self.content_type_len = copyInto(&self.content_type_buf, content_type);
    }

    const Snapshot = struct { calls: u32, path: []const u8, body: []const u8, content_type: []const u8 };

    fn snapshot(self: *Captured, alc: std.mem.Allocator) !Snapshot {
        self.acquire();
        defer self.lock.unlock();
        return .{
            .calls = self.calls,
            .path = try alc.dupe(u8, self.path_buf[0..self.path_len]),
            .body = try alc.dupe(u8, self.body_buf[0..self.body_len]),
            .content_type = try alc.dupe(u8, self.content_type_buf[0..self.content_type_len]),
        };
    }
};

fn copyInto(buf: []u8, value: []const u8) usize {
    const n = @min(buf.len, value.len);
    @memcpy(buf[0..n], value[0..n]);
    return n;
}

var captured: Captured = .{};

/// What the fake does with an authenticated request, decided by an address
/// in the body: the provider-specific rejection, a rate limit, a failure,
/// a success body that carries no id, or (null) plain success.
fn scripted(c: *spider.Ctx, rejected: std.http.Status) !?spider.Response {
    const body = c.body orelse "";
    if (std.mem.indexOf(u8, body, "reject@example.com") != null) {
        return try c.json(.{ .code = "invalid_parameter", .message = "recipient refused" }, .{ .status = rejected });
    }
    if (std.mem.indexOf(u8, body, "busy@example.com") != null) {
        return try c.json(.{ .message = "slow down" }, .{ .status = .too_many_requests });
    }
    if (std.mem.indexOf(u8, body, "boom@example.com") != null) {
        return try c.text("upstream exploded", .{ .status = .internal_server_error });
    }
    if (std.mem.indexOf(u8, body, "noid@example.com") != null) {
        return try c.text("accepted", .{ .status = .accepted });
    }
    return null;
}

fn record(c: *spider.Ctx, path: []const u8) void {
    captured.record(path, c.body orelse "", c.header("Content-Type") orelse "");
}

fn brevoApi(c: *spider.Ctx) !spider.Response {
    record(c, "/v3/smtp/email");
    if (!std.mem.eql(u8, c.header("api-key") orelse "", good_key)) {
        return c.json(.{ .code = "unauthorized", .message = "Key not found" }, .{ .status = .unauthorized });
    }
    if (try scripted(c, .bad_request)) |res| return res;
    return c.json(.{ .messageId = "<brevo-1@smtp-relay.mailin.fr>" }, .{ .status = .created });
}

fn resendApi(c: *spider.Ctx) !spider.Response {
    record(c, "/emails");
    if (!std.mem.eql(u8, c.header("Authorization") orelse "", "Bearer " ++ good_key)) {
        return c.json(.{ .name = "validation_error", .message = "API key is invalid" }, .{ .status = .forbidden });
    }
    if (try scripted(c, .unprocessable_entity)) |res| return res;
    return c.json(.{ .id = "resend-id-1" }, .{});
}

fn postmarkApi(c: *spider.Ctx) !spider.Response {
    record(c, "/email");
    if (!std.mem.eql(u8, c.header("X-Postmark-Server-Token") orelse "", good_key)) {
        return c.json(.{ .ErrorCode = 10, .Message = "Bad or missing Server API token." }, .{ .status = .unauthorized });
    }
    if (try scripted(c, .unprocessable_entity)) |res| return res;
    return c.json(.{ .To = "bob@example.com", .MessageID = "postmark-id-1", .ErrorCode = 0, .Message = "OK" }, .{});
}

fn runProvider(port: u16) void {
    var s = spider.app(.{});
    s
        .post("/v3/smtp/email", brevoApi, .{})
        .post("/emails", resendApi, .{})
        .post("/email", postmarkApi, .{})
        .listen(.{ .port = port, .host = "127.0.0.1" }) catch |err| {
        std.log.warn("fake mail provider listen() failed: {s}", .{@errorName(err)});
    };
}

// ── app under test ──────────────────────────────────────────────────────

fn providerUrl(alc: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(alc, "http://127.0.0.1:{d}", .{provider_port});
}

fn sample(to: []const u8) mail.Mail {
    return .{
        .to = &.{.{ .name = "Bob", .address = to }},
        .cc = &.{.{ .address = "cc@example.com" }},
        .bcc = &.{.{ .address = "bcc@example.com" }},
        .reply_to = .{ .name = "Help", .address = "help@example.com" },
        .subject = "Welcome \"aboard\"",
        .html = "<h1>Ol\u{e1}</h1>",
        .text = "Ol\u{e1}",
    };
}

/// The handler's answer: the message id (or "-" when the provider gave
/// none), or the error name with 502.
fn report(c: *spider.Ctx, result: anyerror!mail.Receipt) !spider.Response {
    const receipt = result catch |err| return c.text(@errorName(err), .{ .status = .bad_gateway });
    return c.text(receipt.message_id orelse "-", .{});
}

/// POST /send/:provider?to=..&key=.. — a Mailer configured like an app's
/// (fromSettings), pointed at the fake provider.
fn sendVia(c: *spider.Ctx) !spider.Response {
    const mailer = mail.Mailer.fromSettings(.{
        .transport = c.params.get("provider") orelse return error.NotFound,
        .from = "App <app@example.com>",
        .api_key = c.query("key") orelse good_key,
        .base_url = try providerUrl(c.arena),
    }) catch |err| return report(c, err);
    const to = [_]mail.Mailbox{.{ .name = "Bob", .address = c.query("to") orelse "bob@example.com" }};
    var message = sample("unused@example.com");
    message.to = &to;
    return report(c, mailer.send(c, message));
}

/// A provider nobody listens on.
fn sendDown(c: *spider.Ctx) !spider.Response {
    const dead_port = try h.reserveEphemeralPort(c._io);
    const mailer: mail.Mailer = .{
        .backend = .{ .brevo = .{
            .api_key = good_key,
            .base_url = try std.fmt.allocPrint(c.arena, "http://127.0.0.1:{d}", .{dead_port}),
        } },
        .from = .{ .address = "app@example.com" },
    };
    return report(c, mailer.send(c, sample("bob@example.com")));
}

/// A mail without recipients: refused before any request is made.
fn sendInvalid(c: *spider.Ctx) !spider.Response {
    const mailer: mail.Mailer = .{
        .backend = .{ .brevo = .{ .api_key = good_key, .base_url = try providerUrl(c.arena) } },
        .from = .{ .address = "app@example.com" },
    };
    return report(c, mailer.send(c, .{ .subject = "Nobody", .text = "Hello" }));
}

fn sendMemory(c: *spider.Ctx) !spider.Response {
    const mailer: mail.Mailer = .{ .backend = .{ .memory = &outbox }, .from = .{ .address = "app@example.com" } };
    const to = [_]mail.Mailbox{.{ .address = c.query("to") orelse "bob@example.com" }};
    return report(c, mailer.send(c, .{ .to = &to, .subject = "From a handler", .text = "Hello" }));
}

fn sendLog(c: *spider.Ctx) !spider.Response {
    const mailer: mail.Mailer = .{ .backend = .{ .log = .{ .body = false } }, .from = .{ .address = "app@example.com" } };
    return report(c, mailer.send(c, sample("bob@example.com")));
}

fn runApp(port: u16) void {
    var s = spider.app(.{});
    s
        .post("/send/down", sendDown, .{})
        .post("/send/invalid", sendInvalid, .{})
        .post("/send/memory", sendMemory, .{})
        .post("/send/log", sendLog, .{})
        .post("/via/:provider", sendVia, .{})
        .listen(.{ .port = port, .host = "127.0.0.1" }) catch |err| {
        std.log.warn("mail app listen() failed: {s}", .{@errorName(err)});
    };
}

fn ensureStarted(io: std.Io) !void {
    try start_mutex.lock(io);
    defer start_mutex.unlock(io);
    if (started) return;

    outbox = .init(std.heap.smp_allocator);

    provider_port = try h.reserveEphemeralPort(io);
    (try std.Thread.spawn(.{}, runProvider, .{provider_port})).detach();
    try h.waitForPort(io, provider_port);

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
    fn alc(self: *Env) std.mem.Allocator {
        return self.arena.allocator();
    }
    fn post(self: *Env, target: []const u8) !h.HttpResponse {
        return h.request(self.threaded.io(), self.alc(), app_port, target, .{ .method = "POST" });
    }
    /// The request the provider received last, with its body parsed.
    fn lastRequest(self: *Env) !struct { calls: u32, path: []const u8, content_type: []const u8, json: std.json.Value } {
        const snap = try captured.snapshot(self.alc());
        return .{
            .calls = snap.calls,
            .path = snap.path,
            .content_type = snap.content_type,
            .json = try std.json.parseFromSliceLeaky(std.json.Value, self.alc(), snap.body, .{}),
        };
    }
    fn providerCalls(self: *Env) !u32 {
        return (try captured.snapshot(self.alc())).calls;
    }
};

fn expectAnswer(res: h.HttpResponse, status: u16, body: []const u8) !void {
    if (res.status != status) std.debug.print("\nexpected {d}, got {d} (body: {s})\n", .{ status, res.status, res.body });
    try std.testing.expectEqual(status, res.status);
    try std.testing.expectEqualStrings(body, res.body);
}

fn str(value: std.json.Value, key: []const u8) []const u8 {
    return value.object.get(key).?.string;
}

// ── delivery through each provider ──────────────────────────────────────

test "mail brevo: the handler's mail reaches the API and the message id comes back" {
    var e = try Env.init();
    defer e.deinit();
    try expectAnswer(try e.post("/via/brevo"), 200, "<brevo-1@smtp-relay.mailin.fr>");

    const req = try e.lastRequest();
    try std.testing.expectEqualStrings("/v3/smtp/email", req.path);
    try std.testing.expectEqualStrings("application/json", req.content_type);
    const sender = req.json.object.get("sender").?;
    try std.testing.expectEqualStrings("app@example.com", str(sender, "email"));
    try std.testing.expectEqualStrings("App", str(sender, "name"));
    const to = req.json.object.get("to").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), to.len);
    try std.testing.expectEqualStrings("bob@example.com", str(to[0], "email"));
    try std.testing.expectEqualStrings("Bob", str(to[0], "name"));
    try std.testing.expectEqualStrings("cc@example.com", str(req.json.object.get("cc").?.array.items[0], "email"));
    try std.testing.expectEqualStrings("bcc@example.com", str(req.json.object.get("bcc").?.array.items[0], "email"));
    try std.testing.expectEqualStrings("help@example.com", str(req.json.object.get("replyTo").?, "email"));
    try std.testing.expectEqualStrings("Welcome \"aboard\"", str(req.json, "subject"));
    try std.testing.expectEqualStrings("<h1>Ol\u{e1}</h1>", str(req.json, "htmlContent"));
    try std.testing.expectEqualStrings("Ol\u{e1}", str(req.json, "textContent"));
}

test "mail resend: the handler's mail reaches the API and the message id comes back" {
    var e = try Env.init();
    defer e.deinit();
    try expectAnswer(try e.post("/via/resend"), 200, "resend-id-1");

    const req = try e.lastRequest();
    try std.testing.expectEqualStrings("/emails", req.path);
    try std.testing.expectEqualStrings("application/json", req.content_type);
    try std.testing.expectEqualStrings("App <app@example.com>", str(req.json, "from"));
    const to = req.json.object.get("to").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), to.len);
    try std.testing.expectEqualStrings("bob@example.com", to[0].string);
    try std.testing.expectEqualStrings("cc@example.com", req.json.object.get("cc").?.array.items[0].string);
    try std.testing.expectEqualStrings("bcc@example.com", req.json.object.get("bcc").?.array.items[0].string);
    try std.testing.expectEqualStrings("help@example.com", str(req.json, "reply_to"));
    try std.testing.expectEqualStrings("Welcome \"aboard\"", str(req.json, "subject"));
    try std.testing.expectEqualStrings("<h1>Ol\u{e1}</h1>", str(req.json, "html"));
    try std.testing.expectEqualStrings("Ol\u{e1}", str(req.json, "text"));
}

test "mail postmark: the handler's mail reaches the API and the message id comes back" {
    var e = try Env.init();
    defer e.deinit();
    try expectAnswer(try e.post("/via/postmark"), 200, "postmark-id-1");

    const req = try e.lastRequest();
    try std.testing.expectEqualStrings("/email", req.path);
    try std.testing.expectEqualStrings("application/json", req.content_type);
    try std.testing.expectEqualStrings("App <app@example.com>", str(req.json, "From"));
    try std.testing.expectEqualStrings("Bob <bob@example.com>", str(req.json, "To"));
    try std.testing.expectEqualStrings("cc@example.com", str(req.json, "Cc"));
    try std.testing.expectEqualStrings("bcc@example.com", str(req.json, "Bcc"));
    try std.testing.expectEqualStrings("Help <help@example.com>", str(req.json, "ReplyTo"));
    try std.testing.expectEqualStrings("Welcome \"aboard\"", str(req.json, "Subject"));
    try std.testing.expectEqualStrings("<h1>Ol\u{e1}</h1>", str(req.json, "HtmlBody"));
    try std.testing.expectEqualStrings("Ol\u{e1}", str(req.json, "TextBody"));
}

// ── provider answers become mail errors ─────────────────────────────────

const providers = [_][]const u8{ "brevo", "resend", "postmark" };

fn expectFailure(e: *Env, comptime query: []const u8, expected_error: []const u8) !void {
    for (providers) |provider| {
        const before = try e.providerCalls();
        const target = try std.fmt.allocPrint(e.alc(), "/via/{s}?" ++ query, .{provider});
        try expectAnswer(try e.post(target), 502, expected_error);
        // The provider was asked exactly once: no hidden retry.
        try std.testing.expectEqual(before + 1, try e.providerCalls());
    }
}

test "mail: a refused API key is MailUnauthorized on every provider" {
    var e = try Env.init();
    defer e.deinit();
    try expectFailure(&e, "key=wrong-key", "MailUnauthorized");
}

test "mail: a message the provider refuses is MailRejected" {
    var e = try Env.init();
    defer e.deinit();
    try expectFailure(&e, "to=reject@example.com", "MailRejected");
}

test "mail: a provider failure is MailDeliveryFailed" {
    var e = try Env.init();
    defer e.deinit();
    try expectFailure(&e, "to=boom@example.com", "MailDeliveryFailed");
}

test "mail: a rate limit is MailDeliveryFailed" {
    var e = try Env.init();
    defer e.deinit();
    try expectFailure(&e, "to=busy@example.com", "MailDeliveryFailed");
}

test "mail: a success without an id in the body is still a success" {
    var e = try Env.init();
    defer e.deinit();
    for (providers) |provider| {
        const target = try std.fmt.allocPrint(e.alc(), "/via/{s}?to=noid@example.com", .{provider});
        try expectAnswer(try e.post(target), 200, "-");
    }
}

test "mail: an unreachable provider is MailDeliveryFailed" {
    var e = try Env.init();
    defer e.deinit();
    try expectAnswer(try e.post("/send/down"), 502, "MailDeliveryFailed");
}

test "mail: an unknown transport name fails before anything is sent" {
    var e = try Env.init();
    defer e.deinit();
    const before = try e.providerCalls();
    try expectAnswer(try e.post("/via/pigeon"), 502, "MailTransportUnknown");
    try std.testing.expectEqual(before, try e.providerCalls());
}

test "mail: an invalid mail is refused without calling the provider" {
    var e = try Env.init();
    defer e.deinit();
    const before = try e.providerCalls();
    try expectAnswer(try e.post("/send/invalid"), 502, "MailMissingRecipients");
    try std.testing.expectEqual(before, try e.providerCalls());
}

// ── the other backends, from a handler ──────────────────────────────────

test "mail memory: what a handler sent is in the outbox after the request" {
    var e = try Env.init();
    defer e.deinit();
    outbox.clear();
    const before = try e.providerCalls();

    const first = try e.post("/send/memory?to=ada@example.com");
    try std.testing.expectEqual(@as(u16, 200), first.status);
    try std.testing.expect(std.mem.endsWith(u8, first.body, "@memory.spider>"));
    _ = try e.post("/send/memory?to=cy@example.com");

    try std.testing.expectEqual(@as(usize, 2), outbox.count());
    try std.testing.expectEqualStrings("ada@example.com", outbox.sent()[0].to[0].address);
    try std.testing.expectEqualStrings("cy@example.com", outbox.last().?.to[0].address);
    try std.testing.expectEqualStrings("From a handler", outbox.last().?.subject);
    try std.testing.expectEqualStrings("app@example.com", outbox.last().?.from.?.address);
    try std.testing.expectEqual(before, try e.providerCalls());
}

test "mail log: accepts the mail and delivers nothing" {
    var e = try Env.init();
    defer e.deinit();
    const before = try e.providerCalls();
    try expectAnswer(try e.post("/send/log"), 200, "-");
    try std.testing.expectEqual(before, try e.providerCalls());
}

// ── outside a request ───────────────────────────────────────────────────

test "mail sendWith: sends without a Ctx (jobs)" {
    var e = try Env.init();
    defer e.deinit();
    const mailer: mail.Mailer = .{
        .backend = .{ .resend = .{ .api_key = good_key, .base_url = try providerUrl(e.alc()) } },
        .from = .{ .name = "Jobs", .address = "jobs@example.com" },
    };

    const receipt = try mailer.sendWith(e.alc(), e.threaded.io(), .{
        .to = &.{.{ .address = "ada@example.com" }},
        .subject = "Nightly digest",
        .text = "Nothing happened",
    });
    try std.testing.expectEqualStrings("resend-id-1", receipt.message_id.?);

    const req = try e.lastRequest();
    try std.testing.expectEqualStrings("Jobs <jobs@example.com>", str(req.json, "from"));
    try std.testing.expectEqualStrings("Nightly digest", str(req.json, "subject"));
    // Fields the mail left out are not sent at all.
    try std.testing.expect(req.json.object.get("cc") == null);
    try std.testing.expect(req.json.object.get("html") == null);
    try std.testing.expect(req.json.object.get("reply_to") == null);

    const refused: mail.Mailer = .{
        .backend = .{ .resend = .{ .api_key = "wrong-key", .base_url = try providerUrl(e.alc()) } },
        .from = .{ .address = "jobs@example.com" },
    };
    try std.testing.expectError(error.MailUnauthorized, refused.sendWith(e.alc(), e.threaded.io(), .{
        .to = &.{.{ .address = "ada@example.com" }},
        .text = "Nothing happened",
    }));
}
