//! Log transport: writes the message to the log instead of delivering it.
//! The development default, so a reset link can be read from the terminal.

const std = @import("std");
const message = @import("message.zig");
const Mail = message.Mail;
const Mailbox = message.Mailbox;
const Receipt = message.Receipt;

const log = std.log.scoped(.mail);

pub const Log = struct {
    /// Also log the body (the text one when there is one, else the HTML).
    body: bool = true,

    pub fn send(self: Log, arena: std.mem.Allocator, mail: Mail) !Receipt {
        log.info("{s}", .{try self.line(arena, mail)});
        return .{};
    }

    /// The log line for a validated mail.
    pub fn line(self: Log, arena: std.mem.Allocator, mail: Mail) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, "mail not delivered (log transport): from=");
        try out.appendSlice(arena, mail.from.?.address);
        try appendList(arena, &out, " to=", mail.to);
        try appendList(arena, &out, " cc=", mail.cc);
        try appendList(arena, &out, " bcc=", mail.bcc);
        try out.appendSlice(arena, " subject=\"");
        try out.appendSlice(arena, mail.subject);
        try out.append(arena, '"');
        if (self.body) {
            try out.append(arena, '\n');
            try out.appendSlice(arena, mail.text orelse mail.html orelse "");
        }
        return out.toOwnedSlice(arena);
    }
};

fn appendList(arena: std.mem.Allocator, out: *std.ArrayList(u8), label: []const u8, mailboxes: []const Mailbox) !void {
    if (mailboxes.len == 0) return;
    try out.appendSlice(arena, label);
    for (mailboxes, 0..) |mailbox, i| {
        if (i > 0) try out.append(arena, ',');
        try out.appendSlice(arena, mailbox.address);
    }
}

// ── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

const sample: Mail = .{
    .from = .{ .name = "Ada", .address = "ada@example.com" },
    .to = &.{ .{ .address = "bob@example.com" }, .{ .address = "cy@example.com" } },
    .subject = "Reset your password",
    .html = "<a href=\"https://example.com/reset\">Reset</a>",
    .text = "https://example.com/reset",
};

test "log line: recipients, subject and the text body" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const log_transport: Log = .{};
    try testing.expectEqualStrings(
        "mail not delivered (log transport): from=ada@example.com to=bob@example.com,cy@example.com" ++
            " subject=\"Reset your password\"\nhttps://example.com/reset",
        try log_transport.line(arena_state.allocator(), sample),
    );
}

test "log line: cc and bcc, and the HTML body when there is no text" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var mail = sample;
    mail.to = &.{};
    mail.cc = &.{.{ .address = "cc@example.com" }};
    mail.bcc = &.{.{ .address = "bcc@example.com" }};
    mail.text = null;
    const log_transport: Log = .{};
    try testing.expectEqualStrings(
        "mail not delivered (log transport): from=ada@example.com cc=cc@example.com bcc=bcc@example.com" ++
            " subject=\"Reset your password\"\n<a href=\"https://example.com/reset\">Reset</a>",
        try log_transport.line(arena_state.allocator(), mail),
    );
}

test "log line: without the body" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const log_transport: Log = .{ .body = false };
    try testing.expectEqualStrings(
        "mail not delivered (log transport): from=ada@example.com to=bob@example.com,cy@example.com" ++
            " subject=\"Reset your password\"",
        try log_transport.line(arena_state.allocator(), sample),
    );
}

test "log send: returns a receipt without an id" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const log_transport: Log = .{ .body = false };
    const receipt = try log_transport.send(arena_state.allocator(), sample);
    try testing.expect(receipt.message_id == null);
}
