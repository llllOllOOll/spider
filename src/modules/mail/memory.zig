//! Memory transport: keeps every message instead of delivering it, so a
//! test can look at what the app sent.

const std = @import("std");
const message = @import("message.zig");
const Mail = message.Mail;
const Mailbox = message.Mailbox;
const Receipt = message.Receipt;

/// Where the memory transport keeps messages. Safe to send to from several
/// threads (handlers) while a test reads it.
pub const Outbox = struct {
    // internal: the fields are the Outbox's state; read it through sent(), count() and last()
    arena: std.heap.ArenaAllocator,
    mails: std.ArrayList(Mail) = .empty,
    next_id: u64 = 1,
    lock: std.atomic.Mutex = .unlocked,

    /// An empty Outbox. The copies of the mails are allocated with
    /// `allocator`; call `deinit()` when done.
    ///
    /// ```zig
    /// var outbox: spider.mail.Outbox = .init(std.testing.allocator);
    /// defer outbox.deinit();
    /// const mailer: spider.mail.Mailer = .{ .backend = .{ .memory = &outbox } };
    /// ```
    pub fn init(allocator: std.mem.Allocator) Outbox {
        return .{ .arena = .init(allocator) };
    }

    /// Frees every stored mail.
    pub fn deinit(self: *Outbox) void {
        self.arena.deinit();
    }

    /// Stores a copy of `mail`: it stays readable after the sender's arena
    /// is gone. The receipt's id is allocated in `arena`.
    pub fn send(self: *Outbox, arena: std.mem.Allocator, mail: Mail) !Receipt {
        self.acquire();
        defer self.lock.unlock();
        try self.mails.append(self.arena.allocator(), try copyMail(self.arena.allocator(), mail));
        const id = self.next_id;
        self.next_id += 1;
        return .{ .message_id = try std.fmt.allocPrint(arena, "<{d}@memory.spider>", .{id}) };
    }

    /// Everything sent so far, oldest first. Valid until clear() or deinit().
    pub fn sent(self: *Outbox) []const Mail {
        self.acquire();
        defer self.lock.unlock();
        return self.mails.items;
    }

    /// How many mails were sent since init() or the last clear().
    pub fn count(self: *Outbox) usize {
        return self.sent().len;
    }

    /// The most recent message, or null when nothing was sent.
    pub fn last(self: *Outbox) ?Mail {
        const mails = self.sent();
        return if (mails.len == 0) null else mails[mails.len - 1];
    }

    /// Forgets every message; slices handed out before are no longer valid.
    pub fn clear(self: *Outbox) void {
        self.acquire();
        defer self.lock.unlock();
        self.mails = .empty;
        _ = self.arena.reset(.free_all);
    }

    fn acquire(self: *Outbox) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }
};

fn copyMail(alc: std.mem.Allocator, mail: Mail) !Mail {
    return .{
        .from = if (mail.from) |from| try copyMailbox(alc, from) else null,
        .to = try copyMailboxes(alc, mail.to),
        .cc = try copyMailboxes(alc, mail.cc),
        .bcc = try copyMailboxes(alc, mail.bcc),
        .reply_to = if (mail.reply_to) |reply_to| try copyMailbox(alc, reply_to) else null,
        .subject = try alc.dupe(u8, mail.subject),
        .html = if (mail.html) |html| try alc.dupe(u8, html) else null,
        .text = if (mail.text) |text| try alc.dupe(u8, text) else null,
    };
}

fn copyMailbox(alc: std.mem.Allocator, mailbox: Mailbox) !Mailbox {
    return .{
        .name = if (mailbox.name) |name| try alc.dupe(u8, name) else null,
        .address = try alc.dupe(u8, mailbox.address),
    };
}

fn copyMailboxes(alc: std.mem.Allocator, mailboxes: []const Mailbox) ![]const Mailbox {
    const out = try alc.alloc(Mailbox, mailboxes.len);
    for (mailboxes, out) |mailbox, *slot| slot.* = try copyMailbox(alc, mailbox);
    return out;
}

// ── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "outbox: starts empty" {
    var outbox: Outbox = .init(testing.allocator);
    defer outbox.deinit();
    try testing.expectEqual(@as(usize, 0), outbox.count());
    try testing.expect(outbox.last() == null);
    try testing.expectEqual(@as(usize, 0), outbox.sent().len);
}

test "outbox: keeps messages in order with increasing ids" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var outbox: Outbox = .init(testing.allocator);
    defer outbox.deinit();

    const first = try outbox.send(arena_state.allocator(), .{ .subject = "one" });
    const second = try outbox.send(arena_state.allocator(), .{ .subject = "two" });
    try testing.expectEqualStrings("<1@memory.spider>", first.message_id.?);
    try testing.expectEqualStrings("<2@memory.spider>", second.message_id.?);
    try testing.expectEqual(@as(usize, 2), outbox.count());
    try testing.expectEqualStrings("one", outbox.sent()[0].subject);
    try testing.expectEqualStrings("two", outbox.last().?.subject);
}

test "outbox: the stored message does not depend on the sender's memory" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var outbox: Outbox = .init(testing.allocator);
    defer outbox.deinit();

    var subject = "Welcome".*;
    var address = "bob@example.com".*;
    var name = "Bob".*;
    var html = "<p>Hi</p>".*;
    var text = "Hi".*;
    const everyone = [_]Mailbox{.{ .name = &name, .address = &address }};
    _ = try outbox.send(arena_state.allocator(), .{
        .from = everyone[0],
        .to = &everyone,
        .cc = &everyone,
        .bcc = &everyone,
        .reply_to = everyone[0],
        .subject = &subject,
        .html = &html,
        .text = &text,
    });
    for ([_][]u8{ &subject, &address, &name, &html, &text }) |buf| @memset(buf, 'x');

    const mail = outbox.last().?;
    try testing.expectEqualStrings("Welcome", mail.subject);
    try testing.expectEqualStrings("<p>Hi</p>", mail.html.?);
    try testing.expectEqualStrings("Hi", mail.text.?);
    for ([_]Mailbox{ mail.from.?, mail.to[0], mail.cc[0], mail.bcc[0], mail.reply_to.? }) |mailbox| {
        try testing.expectEqualStrings("Bob", mailbox.name.?);
        try testing.expectEqualStrings("bob@example.com", mailbox.address);
    }
}

test "outbox: absent optional fields stay absent" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var outbox: Outbox = .init(testing.allocator);
    defer outbox.deinit();

    _ = try outbox.send(arena_state.allocator(), .{ .to = &.{.{ .address = "bob@example.com" }}, .text = "Hi" });
    const mail = outbox.last().?;
    try testing.expect(mail.from == null);
    try testing.expect(mail.reply_to == null);
    try testing.expect(mail.html == null);
    try testing.expect(mail.to[0].name == null);
    try testing.expectEqual(@as(usize, 0), mail.cc.len);
}

test "outbox: clear forgets the messages and keeps counting ids" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var outbox: Outbox = .init(testing.allocator);
    defer outbox.deinit();

    _ = try outbox.send(arena_state.allocator(), .{ .subject = "one" });
    outbox.clear();
    try testing.expectEqual(@as(usize, 0), outbox.count());
    const receipt = try outbox.send(arena_state.allocator(), .{ .subject = "two" });
    try testing.expectEqualStrings("<2@memory.spider>", receipt.message_id.?);
    try testing.expectEqualStrings("two", outbox.last().?.subject);
}

test "outbox: concurrent senders lose nothing" {
    var outbox: Outbox = .init(testing.allocator);
    defer outbox.deinit();

    const per_thread = 200;
    const worker = struct {
        fn run(box: *Outbox) void {
            var arena_state: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
            defer arena_state.deinit();
            for (0..per_thread) |_| {
                _ = box.send(arena_state.allocator(), .{ .subject = "x" }) catch return;
            }
        }
    }.run;

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, worker, .{&outbox});
    for (threads) |t| t.join();
    try testing.expectEqual(@as(usize, threads.len * per_thread), outbox.count());
}
