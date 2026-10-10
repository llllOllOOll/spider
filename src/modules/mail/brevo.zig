//! Brevo transport: the transactional email API (`POST /v3/smtp/email`).
//! Apps use only `Brevo`, as `spider.mail.Brevo`; the rest is internal.

const std = @import("std");
const http = @import("http.zig");
const message = @import("message.zig");
const Mail = message.Mail;
const Mailbox = message.Mailbox;
const Receipt = message.Receipt;

/// Delivery through Brevo: the value of `Backend.brevo`.
pub const Brevo = struct {
    /// The API key, from the provider's dashboard (`Mailer.fromEnv`: BREVO_API_KEY).
    /// Not copied.
    api_key: []const u8,
    /// The API's address, without a trailing slash. Change it for a mock
    /// server or a regional endpoint (`Mailer.fromEnv`: MAIL_BASE_URL).
    base_url: []const u8 = "https://api.brevo.com",
    /// How long one delivery may take, in milliseconds; past that it fails
    /// with `error.MailDeliveryFailed`. 0: no limit.
    timeout_ms: u32 = 30_000,

    // internal: called by Mailer.sendWith; apps send through a Mailer
    pub fn send(self: Brevo, arena: std.mem.Allocator, io: std.Io, mail: Mail) !Receipt {
        const url = try std.fmt.allocPrint(arena, "{s}/v3/smtp/email", .{self.base_url});
        const reply = try http.postJson(arena, io, url, self.timeout_ms, &.{
            .{ .name = "api-key", .value = self.api_key },
            .{ .name = "Accept", .value = "application/json" },
        }, try payload(arena, mail));
        try http.check("brevo", reply);
        return .{ .message_id = http.jsonString(arena, reply.body, "messageId") };
    }
};

const Contact = struct {
    email: []const u8,
    name: ?[]const u8 = null,
};

const Payload = struct {
    sender: Contact,
    to: ?[]const Contact,
    cc: ?[]const Contact,
    bcc: ?[]const Contact,
    replyTo: ?Contact,
    subject: []const u8,
    htmlContent: ?[]const u8,
    textContent: ?[]const u8,
};

/// The request body for a validated mail.
pub fn payload(arena: std.mem.Allocator, mail: Mail) ![]const u8 {
    return http.stringify(arena, Payload{
        .sender = contact(mail.from.?),
        .to = try contacts(arena, mail.to),
        .cc = try contacts(arena, mail.cc),
        .bcc = try contacts(arena, mail.bcc),
        .replyTo = if (mail.reply_to) |reply_to| contact(reply_to) else null,
        .subject = mail.subject,
        .htmlContent = mail.html,
        .textContent = mail.text,
    });
}

fn contact(mailbox: Mailbox) Contact {
    return .{ .email = mailbox.address, .name = mailbox.name };
}

fn contacts(arena: std.mem.Allocator, mailboxes: []const Mailbox) !?[]const Contact {
    if (mailboxes.len == 0) return null;
    const out = try arena.alloc(Contact, mailboxes.len);
    for (mailboxes, out) |mailbox, *slot| slot.* = contact(mailbox);
    return out;
}

// ── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "brevo payload: the minimal message" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings(
        "{\"sender\":{\"email\":\"ada@example.com\"}," ++
            "\"to\":[{\"email\":\"bob@example.com\"}]," ++
            "\"subject\":\"Hi\",\"textContent\":\"Hello\"}",
        try payload(arena_state.allocator(), .{
            .from = .{ .address = "ada@example.com" },
            .to = &.{.{ .address = "bob@example.com" }},
            .subject = "Hi",
            .text = "Hello",
        }),
    );
}

test "brevo payload: every field" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings(
        "{\"sender\":{\"email\":\"ada@example.com\",\"name\":\"Ada\"}," ++
            "\"to\":[{\"email\":\"bob@example.com\",\"name\":\"Bob\"},{\"email\":\"cy@example.com\"}]," ++
            "\"cc\":[{\"email\":\"cc@example.com\"}]," ++
            "\"bcc\":[{\"email\":\"bcc@example.com\"}]," ++
            "\"replyTo\":{\"email\":\"help@example.com\",\"name\":\"Help\"}," ++
            "\"subject\":\"Say \\\"hi\\\"\"," ++
            "\"htmlContent\":\"<p>Ol\u{e1}</p>\",\"textContent\":\"Ol\u{e1}\"}",
        try payload(arena_state.allocator(), .{
            .from = .{ .name = "Ada", .address = "ada@example.com" },
            .to = &.{ .{ .name = "Bob", .address = "bob@example.com" }, .{ .address = "cy@example.com" } },
            .cc = &.{.{ .address = "cc@example.com" }},
            .bcc = &.{.{ .address = "bcc@example.com" }},
            .reply_to = .{ .name = "Help", .address = "help@example.com" },
            .subject = "Say \"hi\"",
            .html = "<p>Ol\u{e1}</p>",
            .text = "Ol\u{e1}",
        }),
    );
}
