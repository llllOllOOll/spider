//! The mail message: Mailbox, Mail, Receipt, and the checks every transport
//! relies on. Nothing here knows how a message is delivered.

const std = @import("std");

/// An address with an optional display name.
pub const Mailbox = struct {
    name: ?[]const u8 = null,
    address: []const u8,

    /// Parses `Ada <ada@example.com>`, `"Lovelace, Ada" <ada@example.com>` or
    /// a bare `ada@example.com`. The result borrows from `s`.
    pub fn parse(s: []const u8) !Mailbox {
        const trimmed = std.mem.trim(u8, s, " \t");
        var mailbox: Mailbox = .{ .address = trimmed };
        if (std.mem.endsWith(u8, trimmed, ">")) {
            const open = std.mem.lastIndexOfScalar(u8, trimmed, '<') orelse return error.MailInvalidAddress;
            mailbox.address = trimmed[open + 1 .. trimmed.len - 1];
            var name = std.mem.trim(u8, trimmed[0..open], " \t");
            if (name.len >= 2 and name[0] == '"' and name[name.len - 1] == '"') name = name[1 .. name.len - 1];
            if (name.len > 0) mailbox.name = name;
        }
        try mailbox.validate();
        return mailbox;
    }

    /// `Name <address>` (the name quoted when it needs to be), or the bare
    /// address when there is no name.
    pub fn toHeader(self: Mailbox, arena: std.mem.Allocator) ![]const u8 {
        const name = self.name orelse return self.address;
        if (std.mem.indexOfAny(u8, name, "()<>[]:;@\\,.\"") == null) {
            return std.fmt.allocPrint(arena, "{s} <{s}>", .{ name, self.address });
        }
        var out: std.ArrayList(u8) = .empty;
        try out.append(arena, '"');
        for (name) |ch| {
            if (ch == '"' or ch == '\\') try out.append(arena, '\\');
            try out.append(arena, ch);
        }
        try out.appendSlice(arena, "\" <");
        try out.appendSlice(arena, self.address);
        try out.append(arena, '>');
        return out.toOwnedSlice(arena);
    }

    /// `error.MailInvalidAddress` when the address is not well formed,
    /// `error.MailInvalidHeader` when the name has a control character.
    pub fn validate(self: Mailbox) !void {
        if (self.name) |name| try validateHeaderText(name);
        try validateAddress(self.address);
    }
};

/// A message to send. `from` may be left out when the Mailer has a default.
pub const Mail = struct {
    from: ?Mailbox = null,
    to: []const Mailbox = &.{},
    cc: []const Mailbox = &.{},
    bcc: []const Mailbox = &.{},
    reply_to: ?Mailbox = null,
    subject: []const u8 = "",
    html: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

/// What a transport returns once it accepted a message. Acceptance is not
/// inbox delivery.
pub const Receipt = struct {
    /// The id the transport gave the message, when it gave one.
    message_id: ?[]const u8 = null,
};

/// Checks a message before it reaches a transport: a sender, at least one
/// recipient, a body, well-formed addresses, and no control characters
/// (CR/LF above all) in anything that ends up in a header.
pub fn validate(mail: Mail) !void {
    const from = mail.from orelse return error.MailMissingFrom;
    try from.validate();
    if (mail.to.len + mail.cc.len + mail.bcc.len == 0) return error.MailMissingRecipients;
    for ([_][]const Mailbox{ mail.to, mail.cc, mail.bcc }) |list| {
        for (list) |mailbox| try mailbox.validate();
    }
    if (mail.reply_to) |reply_to| try reply_to.validate();
    try validateHeaderText(mail.subject);
    if (isBlank(mail.html) and isBlank(mail.text)) return error.MailMissingBody;
}

fn isBlank(body: ?[]const u8) bool {
    return (body orelse return true).len == 0;
}

fn validateHeaderText(value: []const u8) !void {
    for (value) |ch| {
        if (ch < 0x20 or ch == 0x7f) return error.MailInvalidHeader;
    }
}

/// Not a full RFC 5322 parser: one `@`, something on both sides, and none
/// of the characters that would let an address break out of a header or a
/// recipient list. Quoted local parts are refused.
fn validateAddress(address: []const u8) !void {
    if (address.len == 0 or address.len > 254) return error.MailInvalidAddress;
    for (address) |ch| {
        if (ch <= 0x20 or ch == 0x7f) return error.MailInvalidAddress;
        if (std.mem.indexOfScalar(u8, "<>,;:\"()[]\\", ch) != null) return error.MailInvalidAddress;
    }
    const at = std.mem.indexOfScalar(u8, address, '@') orelse return error.MailInvalidAddress;
    if (std.mem.lastIndexOfScalar(u8, address, '@') != at) return error.MailInvalidAddress;
    const domain = address[at + 1 ..];
    if (at == 0 or domain.len == 0) return error.MailInvalidAddress;
    if (domain[0] == '.' or domain[domain.len - 1] == '.') return error.MailInvalidAddress;
}

// ── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

const ada: Mailbox = .{ .name = "Ada", .address = "ada@example.com" };
const bob: Mailbox = .{ .address = "bob@example.com" };

fn validMail() Mail {
    return .{ .from = ada, .to = &.{bob}, .subject = "Hi", .text = "Hello" };
}

test "Mailbox.parse: bare address" {
    const m = try Mailbox.parse("  ada@example.com ");
    try testing.expectEqualStrings("ada@example.com", m.address);
    try testing.expect(m.name == null);
}

test "Mailbox.parse: name and address" {
    const m = try Mailbox.parse("Ada Lovelace <ada@example.com>");
    try testing.expectEqualStrings("ada@example.com", m.address);
    try testing.expectEqualStrings("Ada Lovelace", m.name.?);
}

test "Mailbox.parse: quoted name loses its quotes" {
    const m = try Mailbox.parse("\"Lovelace, Ada\" <ada@example.com>");
    try testing.expectEqualStrings("Lovelace, Ada", m.name.?);
}

test "Mailbox.parse: angle brackets without a name" {
    const m = try Mailbox.parse("<ada@example.com>");
    try testing.expectEqualStrings("ada@example.com", m.address);
    try testing.expect(m.name == null);
}

test "Mailbox.parse: refuses what is not an address" {
    try testing.expectError(error.MailInvalidAddress, Mailbox.parse(""));
    try testing.expectError(error.MailInvalidAddress, Mailbox.parse("Ada"));
    try testing.expectError(error.MailInvalidAddress, Mailbox.parse("Ada ada@example.com>"));
    try testing.expectError(error.MailInvalidAddress, Mailbox.parse("Ada <not-an-address>"));
}

test "Mailbox.toHeader: bare, named, and quoted when the name needs it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("bob@example.com", try bob.toHeader(arena));
    try testing.expectEqualStrings("Ada <ada@example.com>", try ada.toHeader(arena));
    const comma: Mailbox = .{ .name = "Lovelace, Ada", .address = "ada@example.com" };
    try testing.expectEqualStrings("\"Lovelace, Ada\" <ada@example.com>", try comma.toHeader(arena));
    const quote: Mailbox = .{ .name = "Ada \"the\" \\ first", .address = "ada@example.com" };
    try testing.expectEqualStrings("\"Ada \\\"the\\\" \\\\ first\" <ada@example.com>", try quote.toHeader(arena));
}

test "Mailbox.toHeader: round-trips through parse" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const comma: Mailbox = .{ .name = "Lovelace, Ada", .address = "ada@example.com" };
    const parsed = try Mailbox.parse(try comma.toHeader(arena_state.allocator()));
    try testing.expectEqualStrings("Lovelace, Ada", parsed.name.?);
    try testing.expectEqualStrings("ada@example.com", parsed.address);
}

test "validate: a complete message passes" {
    try validate(validMail());
}

test "validate: html alone, cc alone and bcc alone are enough" {
    var mail = validMail();
    mail.text = null;
    mail.html = "<p>Hello</p>";
    try validate(mail);
    mail.to = &.{};
    mail.cc = &.{bob};
    try validate(mail);
    mail.cc = &.{};
    mail.bcc = &.{bob};
    try validate(mail);
}

test "validate: an empty subject is allowed" {
    var mail = validMail();
    mail.subject = "";
    try validate(mail);
}

test "validate: missing sender" {
    var mail = validMail();
    mail.from = null;
    try testing.expectError(error.MailMissingFrom, validate(mail));
}

test "validate: missing recipients" {
    var mail = validMail();
    mail.to = &.{};
    try testing.expectError(error.MailMissingRecipients, validate(mail));
}

test "validate: missing body, including empty strings" {
    var mail = validMail();
    mail.text = null;
    try testing.expectError(error.MailMissingBody, validate(mail));
    mail.text = "";
    mail.html = "";
    try testing.expectError(error.MailMissingBody, validate(mail));
}

test "validate: malformed addresses in every position" {
    const long_local: [250]u8 = @splat('a');
    const bad = [_][]const u8{
        "",                 "plain",             "@example.com",                    "ada@",
        "a@b@example.com",  "ada @example.com",  "ada@example.com\r\n",             "ada@.example.com",
        "ada@example.com.", "<ada@example.com>", "ada@example.com,bob@example.com", &(long_local ++ "@b.co".*),
    };
    for (bad) |address| {
        const mailbox: Mailbox = .{ .address = address };
        var mail = validMail();
        mail.from = mailbox;
        try testing.expectError(error.MailInvalidAddress, validate(mail));
        mail = validMail();
        mail.to = &.{mailbox};
        try testing.expectError(error.MailInvalidAddress, validate(mail));
        mail = validMail();
        mail.cc = &.{mailbox};
        try testing.expectError(error.MailInvalidAddress, validate(mail));
        mail = validMail();
        mail.bcc = &.{mailbox};
        try testing.expectError(error.MailInvalidAddress, validate(mail));
        mail = validMail();
        mail.reply_to = mailbox;
        try testing.expectError(error.MailInvalidAddress, validate(mail));
    }
}

test "validate: non-ASCII addresses and names are accepted" {
    var mail = validMail();
    mail.to = &.{.{ .name = "João", .address = "joão@exemplo.com.br" }};
    mail.subject = "Olá, João";
    try validate(mail);
}

test "validate: CR/LF and control characters cannot reach a header" {
    var mail = validMail();
    mail.subject = "Hi\r\nBcc: eve@example.com";
    try testing.expectError(error.MailInvalidHeader, validate(mail));

    mail = validMail();
    mail.subject = "Hi\x00";
    try testing.expectError(error.MailInvalidHeader, validate(mail));

    mail = validMail();
    mail.from = .{ .name = "Ada\nBcc: eve@example.com", .address = "ada@example.com" };
    try testing.expectError(error.MailInvalidHeader, validate(mail));

    mail = validMail();
    mail.to = &.{.{ .name = "Bob\r", .address = "bob@example.com" }};
    try testing.expectError(error.MailInvalidHeader, validate(mail));
}
