//! Resend transport (`POST /emails`). Apps use only `Resend`, as
//! `spider.mail.Resend`; the rest is internal.

const std = @import("std");
const http = @import("http.zig");
const message = @import("message.zig");
const Mail = message.Mail;
const Mailbox = message.Mailbox;
const Receipt = message.Receipt;

/// Delivery through Resend: the value of `Backend.resend`. Recipients and
/// `reply_to` are sent as bare addresses: their display names are dropped.
pub const Resend = struct {
    /// The API key, from the provider's dashboard (`Mailer.fromEnv`: RESEND_API_KEY).
    /// Not copied.
    api_key: []const u8,
    /// The API's address, without a trailing slash. Change it for a mock
    /// server or a regional endpoint (`Mailer.fromEnv`: MAIL_BASE_URL).
    base_url: []const u8 = "https://api.resend.com",

    // internal: called by Mailer.sendWith; apps send through a Mailer
    pub fn send(self: Resend, arena: std.mem.Allocator, io: std.Io, mail: Mail) !Receipt {
        const url = try std.fmt.allocPrint(arena, "{s}/emails", .{self.base_url});
        const reply = try http.postJson(arena, io, url, &.{
            .{ .name = "Authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.api_key}) },
        }, try payload(arena, mail));
        try http.check("resend", reply);
        return .{ .message_id = http.jsonString(arena, reply.body, "id") };
    }
};

const Payload = struct {
    from: []const u8,
    to: ?[]const []const u8,
    cc: ?[]const []const u8,
    bcc: ?[]const []const u8,
    reply_to: ?[]const u8,
    subject: []const u8,
    html: ?[]const u8,
    text: ?[]const u8,
};

/// The request body for a validated mail. Recipients go as bare addresses:
/// their display names are not sent.
pub fn payload(arena: std.mem.Allocator, mail: Mail) ![]const u8 {
    return http.stringify(arena, Payload{
        .from = try mail.from.?.toHeader(arena),
        .to = try addresses(arena, mail.to),
        .cc = try addresses(arena, mail.cc),
        .bcc = try addresses(arena, mail.bcc),
        .reply_to = if (mail.reply_to) |reply_to| reply_to.address else null,
        .subject = mail.subject,
        .html = mail.html,
        .text = mail.text,
    });
}

fn addresses(arena: std.mem.Allocator, mailboxes: []const Mailbox) !?[]const []const u8 {
    if (mailboxes.len == 0) return null;
    const out = try arena.alloc([]const u8, mailboxes.len);
    for (mailboxes, out) |mailbox, *slot| slot.* = mailbox.address;
    return out;
}

// ── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "resend payload: the minimal message" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings(
        "{\"from\":\"ada@example.com\",\"to\":[\"bob@example.com\"]," ++
            "\"subject\":\"Hi\",\"text\":\"Hello\"}",
        try payload(arena_state.allocator(), .{
            .from = .{ .address = "ada@example.com" },
            .to = &.{.{ .address = "bob@example.com" }},
            .subject = "Hi",
            .text = "Hello",
        }),
    );
}

test "resend payload: every field" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings(
        "{\"from\":\"Ada <ada@example.com>\"," ++
            "\"to\":[\"bob@example.com\",\"cy@example.com\"]," ++
            "\"cc\":[\"cc@example.com\"],\"bcc\":[\"bcc@example.com\"]," ++
            "\"reply_to\":\"help@example.com\"," ++
            "\"subject\":\"Hi\",\"html\":\"<p>Hello</p>\",\"text\":\"Hello\"}",
        try payload(arena_state.allocator(), .{
            .from = .{ .name = "Ada", .address = "ada@example.com" },
            .to = &.{ .{ .name = "Bob", .address = "bob@example.com" }, .{ .address = "cy@example.com" } },
            .cc = &.{.{ .address = "cc@example.com" }},
            .bcc = &.{.{ .address = "bcc@example.com" }},
            .reply_to = .{ .name = "Help", .address = "help@example.com" },
            .subject = "Hi",
            .html = "<p>Hello</p>",
            .text = "Hello",
        }),
    );
}
