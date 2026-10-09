//! Postmark transport (`POST /email`). Apps use only `Postmark`, as
//! `spider.mail.Postmark`; the rest is internal.

const std = @import("std");
const http = @import("http.zig");
const message = @import("message.zig");
const Mail = message.Mail;
const Mailbox = message.Mailbox;
const Receipt = message.Receipt;

/// Delivery through Postmark: the value of `Backend.postmark`.
pub const Postmark = struct {
    /// The server token (`X-Postmark-Server-Token`).
    api_key: []const u8,
    /// The API's address, without a trailing slash. Change it for a mock
    /// server or a regional endpoint (`Mailer.fromEnv`: MAIL_BASE_URL).
    base_url: []const u8 = "https://api.postmarkapp.com",

    // internal: called by Mailer.sendWith; apps send through a Mailer
    pub fn send(self: Postmark, arena: std.mem.Allocator, io: std.Io, mail: Mail) !Receipt {
        const url = try std.fmt.allocPrint(arena, "{s}/email", .{self.base_url});
        const reply = try http.postJson(arena, io, url, &.{
            .{ .name = "X-Postmark-Server-Token", .value = self.api_key },
            .{ .name = "Accept", .value = "application/json" },
        }, try payload(arena, mail));
        try http.check("postmark", reply);
        return .{ .message_id = http.jsonString(arena, reply.body, "MessageID") };
    }
};

const Payload = struct {
    From: []const u8,
    To: ?[]const u8,
    Cc: ?[]const u8,
    Bcc: ?[]const u8,
    ReplyTo: ?[]const u8,
    Subject: []const u8,
    HtmlBody: ?[]const u8,
    TextBody: ?[]const u8,
};

/// The request body for a validated mail. Postmark takes each recipient
/// list as one comma-separated string.
pub fn payload(arena: std.mem.Allocator, mail: Mail) ![]const u8 {
    return http.stringify(arena, Payload{
        .From = try mail.from.?.toHeader(arena),
        .To = try list(arena, mail.to),
        .Cc = try list(arena, mail.cc),
        .Bcc = try list(arena, mail.bcc),
        .ReplyTo = if (mail.reply_to) |reply_to| try reply_to.toHeader(arena) else null,
        .Subject = mail.subject,
        .HtmlBody = mail.html,
        .TextBody = mail.text,
    });
}

fn list(arena: std.mem.Allocator, mailboxes: []const Mailbox) !?[]const u8 {
    if (mailboxes.len == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    for (mailboxes, 0..) |mailbox, i| {
        if (i > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, try mailbox.toHeader(arena));
    }
    return try out.toOwnedSlice(arena);
}

// ── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "postmark payload: the minimal message" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings(
        "{\"From\":\"ada@example.com\",\"To\":\"bob@example.com\"," ++
            "\"Subject\":\"Hi\",\"TextBody\":\"Hello\"}",
        try payload(arena_state.allocator(), .{
            .from = .{ .address = "ada@example.com" },
            .to = &.{.{ .address = "bob@example.com" }},
            .subject = "Hi",
            .text = "Hello",
        }),
    );
}

test "postmark payload: every field, names quoted where a comma would split the list" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings(
        "{\"From\":\"Ada <ada@example.com>\"," ++
            "\"To\":\"\\\"Builder, Bob\\\" <bob@example.com>, cy@example.com\"," ++
            "\"Cc\":\"cc@example.com\",\"Bcc\":\"bcc@example.com\"," ++
            "\"ReplyTo\":\"Help <help@example.com>\"," ++
            "\"Subject\":\"Hi\",\"HtmlBody\":\"<p>Hello</p>\",\"TextBody\":\"Hello\"}",
        try payload(arena_state.allocator(), .{
            .from = .{ .name = "Ada", .address = "ada@example.com" },
            .to = &.{ .{ .name = "Builder, Bob", .address = "bob@example.com" }, .{ .address = "cy@example.com" } },
            .cc = &.{.{ .address = "cc@example.com" }},
            .bcc = &.{.{ .address = "bcc@example.com" }},
            .reply_to = .{ .name = "Help", .address = "help@example.com" },
            .subject = "Hi",
            .html = "<p>Hello</p>",
            .text = "Hello",
        }),
    );
}
