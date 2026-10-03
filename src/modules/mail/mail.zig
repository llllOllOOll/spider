//! Sending mail (`spider.mail`). The app builds a `Mail` and hands it to a
//! `Mailer`; the Mailer's backend decides how it leaves the process:
//!
//!   var mailer = try spider.mail.Mailer.fromEnv(); // once, at startup
//!   _ = try mailer.send(c, .{
//!       .to = &.{.{ .address = "ada@example.com" }},
//!       .subject = "Welcome",
//!       .html = "<h1>Welcome!</h1>",
//!       .text = "Welcome!",
//!   });
//!
//! This is a client of mail providers (their HTTP APIs), not a mail server:
//! it does not deliver to inboxes itself and does not receive mail.
//!
//! Backends: `.brevo`, `.resend`, `.postmark` (real delivery), `.log`
//! (development), `.memory` (tests, with an `Outbox`), `.custom` (the app's
//! own `Transport`).

const std = @import("std");
const Ctx = @import("../../core/context.zig").Ctx;
const env = @import("../../internal/env.zig");
const message = @import("message.zig");

pub const Mail = message.Mail;
pub const Mailbox = message.Mailbox;
pub const Receipt = message.Receipt;
pub const validate = message.validate;
pub const Brevo = @import("brevo.zig").Brevo;
pub const Resend = @import("resend.zig").Resend;
pub const Postmark = @import("postmark.zig").Postmark;
pub const Log = @import("log.zig").Log;
pub const Outbox = @import("memory.zig").Outbox;

/// A transport written by the app (another provider, a queue, ...):
/// `.{ .custom = .{ .ptr = &my_state, .sendFn = mySend } }`. `sendFn` gets a
/// message that already passed `validate`, with `from` set.
pub const Transport = struct {
    ptr: *anyopaque,
    sendFn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, io: std.Io, mail: Mail) anyerror!Receipt,
};

pub const Backend = union(enum) {
    brevo: Brevo,
    resend: Resend,
    postmark: Postmark,
    log: Log,
    memory: *Outbox,
    custom: Transport,
};

/// What `Mailer.fromSettings` reads; `Mailer.fromEnv` fills it from the
/// environment.
pub const Settings = struct {
    /// "brevo", "resend", "postmark" or "log".
    transport: []const u8 = "log",
    /// The default sender: "Name <address>" or a bare address.
    from: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    /// Replaces the provider's API URL (a mock server, a regional endpoint).
    base_url: ?[]const u8 = null,
};

pub const Mailer = struct {
    backend: Backend,
    /// The sender of a mail that declares none.
    from: ?Mailbox = null,

    /// Sends from a handler.
    ///
    /// Errors: `MailMissingFrom`, `MailMissingRecipients`, `MailMissingBody`,
    /// `MailInvalidAddress`, `MailInvalidHeader` (nothing was sent);
    /// `MailUnauthorized` (the provider refused the API key), `MailRejected`
    /// (it refused this message), `MailDeliveryFailed` (network, rate limit or
    /// provider failure: worth retrying).
    pub fn send(self: Mailer, c: *Ctx, mail: Mail) anyerror!Receipt {
        return self.sendWith(c.arena, c._io, mail);
    }

    /// Sends outside a request (jobs, boot): `mailer.sendWith(arena, hub.io, mail)`.
    pub fn sendWith(self: Mailer, arena: std.mem.Allocator, io: std.Io, mail: Mail) anyerror!Receipt {
        var resolved = mail;
        if (resolved.from == null) resolved.from = self.from;
        try message.validate(resolved);
        return switch (self.backend) {
            .brevo => |brevo| brevo.send(arena, io, resolved),
            .resend => |resend| resend.send(arena, io, resolved),
            .postmark => |postmark| postmark.send(arena, io, resolved),
            .log => |log| log.send(arena, resolved),
            .memory => |outbox| outbox.send(arena, resolved),
            .custom => |transport| transport.sendFn(transport.ptr, arena, io, resolved),
        };
    }

    /// The result borrows the strings of `settings`.
    pub fn fromSettings(settings: Settings) !Mailer {
        const Kind = enum { brevo, resend, postmark, log };
        const kind = std.meta.stringToEnum(Kind, settings.transport) orelse return error.MailTransportUnknown;
        const from: ?Mailbox = if (settings.from) |from| try Mailbox.parse(from) else null;
        if (kind == .log) return .{ .backend = .{ .log = .{} }, .from = from };

        const api_key = settings.api_key orelse return error.MailApiKeyMissing;
        if (api_key.len == 0) return error.MailApiKeyMissing;
        var mailer: Mailer = .{ .from = from, .backend = switch (kind) {
            .brevo => .{ .brevo = .{ .api_key = api_key } },
            .resend => .{ .resend = .{ .api_key = api_key } },
            .postmark => .{ .postmark = .{ .api_key = api_key } },
            .log => unreachable,
        } };
        if (settings.base_url) |base_url| switch (mailer.backend) {
            .brevo => |*brevo| brevo.base_url = base_url,
            .resend => |*resend| resend.base_url = base_url,
            .postmark => |*postmark| postmark.base_url = base_url,
            else => unreachable,
        };
        return mailer;
    }

    /// Reads MAIL_TRANSPORT (brevo | resend | postmark | log, default log),
    /// MAIL_FROM, MAIL_BASE_URL and the transport's key: BREVO_API_KEY,
    /// RESEND_API_KEY or POSTMARK_SERVER_TOKEN. Call it once at startup and
    /// keep the Mailer (each call copies the variables it reads).
    pub fn fromEnv() !Mailer {
        return fromLookup(env.get);
    }

    /// fromEnv() over any variable lookup.
    pub fn fromLookup(lookup: *const fn (key: []const u8) ?[]const u8) !Mailer {
        const transport = nonEmpty(lookup("MAIL_TRANSPORT")) orelse "log";
        const key_var: ?[]const u8 = if (std.mem.eql(u8, transport, "brevo"))
            "BREVO_API_KEY"
        else if (std.mem.eql(u8, transport, "resend"))
            "RESEND_API_KEY"
        else if (std.mem.eql(u8, transport, "postmark"))
            "POSTMARK_SERVER_TOKEN"
        else
            null;
        return fromSettings(.{
            .transport = transport,
            .from = nonEmpty(lookup("MAIL_FROM")),
            .api_key = if (key_var) |name| lookup(name) else null,
            .base_url = nonEmpty(lookup("MAIL_BASE_URL")),
        });
    }
};

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

// ── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

const bob: Mailbox = .{ .address = "bob@example.com" };

/// A custom transport that records what it was given.
const Recorder = struct {
    calls: usize = 0,
    last_from: []const u8 = "",
    fail_with: ?anyerror = null,

    fn sendFn(ptr: *anyopaque, _: std.mem.Allocator, _: std.Io, mail: Mail) anyerror!Receipt {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        self.last_from = mail.from.?.address;
        if (self.fail_with) |err| return err;
        return .{ .message_id = "custom-1" };
    }

    fn mailer(self: *Recorder) Mailer {
        return .{ .backend = .{ .custom = .{ .ptr = self, .sendFn = sendFn } } };
    }
};

const TestEnv = struct {
    threaded: std.Io.Threaded,
    arena: std.heap.ArenaAllocator,

    fn init() TestEnv {
        return .{ .threaded = .init(testing.allocator, .{}), .arena = .init(testing.allocator) };
    }
    fn deinit(self: *TestEnv) void {
        self.arena.deinit();
        self.threaded.deinit();
    }
};

test "sendWith: memory backend stores the message" {
    var t = TestEnv.init();
    defer t.deinit();
    var outbox: Outbox = .init(testing.allocator);
    defer outbox.deinit();
    const mailer: Mailer = .{ .backend = .{ .memory = &outbox } };

    const receipt = try mailer.sendWith(t.arena.allocator(), t.threaded.io(), .{
        .from = .{ .address = "ada@example.com" },
        .to = &.{bob},
        .subject = "Hi",
        .text = "Hello",
    });
    try testing.expectEqualStrings("<1@memory.spider>", receipt.message_id.?);
    try testing.expectEqual(@as(usize, 1), outbox.count());
    try testing.expectEqualStrings("Hi", outbox.last().?.subject);
    try testing.expectEqualStrings("bob@example.com", outbox.last().?.to[0].address);
}

test "sendWith: the mailer's sender fills in a mail without one" {
    var t = TestEnv.init();
    defer t.deinit();
    var outbox: Outbox = .init(testing.allocator);
    defer outbox.deinit();
    const mailer: Mailer = .{
        .backend = .{ .memory = &outbox },
        .from = .{ .name = "App", .address = "app@example.com" },
    };

    _ = try mailer.sendWith(t.arena.allocator(), t.threaded.io(), .{ .to = &.{bob}, .text = "Hello" });
    try testing.expectEqualStrings("app@example.com", outbox.last().?.from.?.address);
    try testing.expectEqualStrings("App", outbox.last().?.from.?.name.?);
}

test "sendWith: the mail's own sender wins over the mailer's" {
    var t = TestEnv.init();
    defer t.deinit();
    var outbox: Outbox = .init(testing.allocator);
    defer outbox.deinit();
    const mailer: Mailer = .{ .backend = .{ .memory = &outbox }, .from = .{ .address = "app@example.com" } };

    _ = try mailer.sendWith(t.arena.allocator(), t.threaded.io(), .{
        .from = .{ .address = "billing@example.com" },
        .to = &.{bob},
        .text = "Hello",
    });
    try testing.expectEqualStrings("billing@example.com", outbox.last().?.from.?.address);
}

test "sendWith: an invalid mail never reaches the backend" {
    var t = TestEnv.init();
    defer t.deinit();
    var outbox: Outbox = .init(testing.allocator);
    defer outbox.deinit();
    const mailer: Mailer = .{ .backend = .{ .memory = &outbox } };
    const arena = t.arena.allocator();
    const io = t.threaded.io();

    try testing.expectError(error.MailMissingFrom, mailer.sendWith(arena, io, .{ .to = &.{bob}, .text = "Hello" }));
    const with_from: Mailer = .{ .backend = .{ .memory = &outbox }, .from = .{ .address = "app@example.com" } };
    try testing.expectError(error.MailMissingRecipients, with_from.sendWith(arena, io, .{ .text = "Hello" }));
    try testing.expectError(error.MailMissingBody, with_from.sendWith(arena, io, .{ .to = &.{bob} }));
    try testing.expectError(error.MailInvalidAddress, with_from.sendWith(arena, io, .{
        .to = &.{.{ .address = "nope" }},
        .text = "Hello",
    }));
    try testing.expectError(error.MailInvalidHeader, with_from.sendWith(arena, io, .{
        .to = &.{bob},
        .subject = "a\r\nb",
        .text = "Hello",
    }));
    try testing.expectEqual(@as(usize, 0), outbox.count());
}

test "sendWith: log backend accepts the mail" {
    var t = TestEnv.init();
    defer t.deinit();
    const mailer: Mailer = .{ .backend = .{ .log = .{ .body = false } }, .from = .{ .address = "app@example.com" } };
    const receipt = try mailer.sendWith(t.arena.allocator(), t.threaded.io(), .{ .to = &.{bob}, .text = "Hello" });
    try testing.expect(receipt.message_id == null);
}

test "sendWith: custom transport gets the resolved mail and its receipt comes back" {
    var t = TestEnv.init();
    defer t.deinit();
    var recorder: Recorder = .{};
    var mailer = recorder.mailer();
    mailer.from = .{ .address = "app@example.com" };

    const receipt = try mailer.sendWith(t.arena.allocator(), t.threaded.io(), .{ .to = &.{bob}, .text = "Hello" });
    try testing.expectEqualStrings("custom-1", receipt.message_id.?);
    try testing.expectEqual(@as(usize, 1), recorder.calls);
    try testing.expectEqualStrings("app@example.com", recorder.last_from);
}

test "sendWith: a custom transport's error reaches the caller" {
    var t = TestEnv.init();
    defer t.deinit();
    var recorder: Recorder = .{ .fail_with = error.MailDeliveryFailed };
    const mailer = recorder.mailer();

    try testing.expectError(error.MailDeliveryFailed, mailer.sendWith(t.arena.allocator(), t.threaded.io(), .{
        .from = .{ .address = "ada@example.com" },
        .to = &.{bob},
        .text = "Hello",
    }));
    try testing.expectEqual(@as(usize, 1), recorder.calls);
}

test "sendWith: a custom transport is not called for an invalid mail" {
    var t = TestEnv.init();
    defer t.deinit();
    var recorder: Recorder = .{};
    const mailer = recorder.mailer();
    try testing.expectError(error.MailMissingFrom, mailer.sendWith(t.arena.allocator(), t.threaded.io(), .{
        .to = &.{bob},
        .text = "Hello",
    }));
    try testing.expectEqual(@as(usize, 0), recorder.calls);
}

test "fromSettings: defaults to the log transport" {
    const mailer = try Mailer.fromSettings(.{});
    try testing.expect(mailer.backend == .log);
    try testing.expect(mailer.from == null);
}

test "fromSettings: each provider with its key and default URL" {
    const brevo = try Mailer.fromSettings(.{ .transport = "brevo", .api_key = "k1" });
    try testing.expectEqualStrings("k1", brevo.backend.brevo.api_key);
    try testing.expectEqualStrings("https://api.brevo.com", brevo.backend.brevo.base_url);

    const resend = try Mailer.fromSettings(.{ .transport = "resend", .api_key = "k2" });
    try testing.expectEqualStrings("k2", resend.backend.resend.api_key);
    try testing.expectEqualStrings("https://api.resend.com", resend.backend.resend.base_url);

    const postmark = try Mailer.fromSettings(.{ .transport = "postmark", .api_key = "k3" });
    try testing.expectEqualStrings("k3", postmark.backend.postmark.api_key);
    try testing.expectEqualStrings("https://api.postmarkapp.com", postmark.backend.postmark.base_url);
}

test "fromSettings: base_url replaces the provider's URL" {
    const url = "http://127.0.0.1:9999";
    const brevo = try Mailer.fromSettings(.{ .transport = "brevo", .api_key = "k", .base_url = url });
    try testing.expectEqualStrings(url, brevo.backend.brevo.base_url);
    const resend = try Mailer.fromSettings(.{ .transport = "resend", .api_key = "k", .base_url = url });
    try testing.expectEqualStrings(url, resend.backend.resend.base_url);
    const postmark = try Mailer.fromSettings(.{ .transport = "postmark", .api_key = "k", .base_url = url });
    try testing.expectEqualStrings(url, postmark.backend.postmark.base_url);
}

test "fromSettings: parses the default sender" {
    const mailer = try Mailer.fromSettings(.{ .from = "OrbitX <no-reply@example.com>" });
    try testing.expectEqualStrings("OrbitX", mailer.from.?.name.?);
    try testing.expectEqualStrings("no-reply@example.com", mailer.from.?.address);
}

test "fromSettings: refuses a bad configuration" {
    try testing.expectError(error.MailTransportUnknown, Mailer.fromSettings(.{ .transport = "smtp" }));
    try testing.expectError(error.MailTransportUnknown, Mailer.fromSettings(.{ .transport = "" }));
    try testing.expectError(error.MailApiKeyMissing, Mailer.fromSettings(.{ .transport = "brevo" }));
    try testing.expectError(error.MailApiKeyMissing, Mailer.fromSettings(.{ .transport = "resend", .api_key = "" }));
    try testing.expectError(error.MailInvalidAddress, Mailer.fromSettings(.{ .from = "not an address" }));
}

fn lookupIn(comptime vars: []const [2][]const u8) *const fn ([]const u8) ?[]const u8 {
    return struct {
        fn get(key: []const u8) ?[]const u8 {
            inline for (vars) |pair| {
                if (std.mem.eql(u8, key, pair[0])) return pair[1];
            }
            return null;
        }
    }.get;
}

test "fromLookup: nothing set is the log transport" {
    const mailer = try Mailer.fromLookup(lookupIn(&.{}));
    try testing.expect(mailer.backend == .log);
    try testing.expect(mailer.from == null);
}

test "fromLookup: empty variables count as unset" {
    const mailer = try Mailer.fromLookup(lookupIn(&.{
        .{ "MAIL_TRANSPORT", "" },
        .{ "MAIL_FROM", "" },
        .{ "MAIL_BASE_URL", "" },
    }));
    try testing.expect(mailer.backend == .log);
    try testing.expect(mailer.from == null);
}

test "fromLookup: each transport reads its own key variable" {
    const all_keys = [_][2][]const u8{
        .{ "BREVO_API_KEY", "brevo-key" },
        .{ "RESEND_API_KEY", "resend-key" },
        .{ "POSTMARK_SERVER_TOKEN", "postmark-token" },
        .{ "MAIL_FROM", "App <app@example.com>" },
    };
    const brevo = try Mailer.fromLookup(lookupIn(&(all_keys ++ [_][2][]const u8{.{ "MAIL_TRANSPORT", "brevo" }})));
    try testing.expectEqualStrings("brevo-key", brevo.backend.brevo.api_key);
    try testing.expectEqualStrings("app@example.com", brevo.from.?.address);

    const resend = try Mailer.fromLookup(lookupIn(&(all_keys ++ [_][2][]const u8{.{ "MAIL_TRANSPORT", "resend" }})));
    try testing.expectEqualStrings("resend-key", resend.backend.resend.api_key);

    const postmark = try Mailer.fromLookup(lookupIn(&(all_keys ++ [_][2][]const u8{.{ "MAIL_TRANSPORT", "postmark" }})));
    try testing.expectEqualStrings("postmark-token", postmark.backend.postmark.api_key);
}

test "fromLookup: MAIL_BASE_URL reaches the provider" {
    const mailer = try Mailer.fromLookup(lookupIn(&.{
        .{ "MAIL_TRANSPORT", "brevo" },
        .{ "BREVO_API_KEY", "k" },
        .{ "MAIL_BASE_URL", "http://127.0.0.1:9999" },
    }));
    try testing.expectEqualStrings("http://127.0.0.1:9999", mailer.backend.brevo.base_url);
}

test "fromLookup: a provider without its key, and an unknown transport" {
    try testing.expectError(error.MailApiKeyMissing, Mailer.fromLookup(lookupIn(&.{
        .{ "MAIL_TRANSPORT", "resend" },
        .{ "BREVO_API_KEY", "wrong-provider" },
    })));
    try testing.expectError(error.MailTransportUnknown, Mailer.fromLookup(lookupIn(&.{
        .{ "MAIL_TRANSPORT", "pigeon" },
    })));
}
