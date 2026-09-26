const std = @import("std");
const posix = std.posix;
const net = std.Io.net;
const Hub = @import("hub.zig").Hub;
const Ctx = @import("../core/context.zig").Ctx;
const Response = @import("../core/context.zig").Response;
const Handler = @import("../routing/router.zig").Handler;

pub const Sse = struct {
    _stream: net.Stream,
    _hub: *Hub,
    _conn_id: u64,
    channel: []const u8 = "",
    params: std.StringHashMapUnmanaged([]const u8) = .{},
    headers: std.StringHashMapUnmanaged([]const u8) = .{},
    arena: std.mem.Allocator,
    io: std.Io,

    pub fn send(self: *Sse, event: []const u8, data: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(self.arena, data, .{});
        defer self.arena.free(json);
        try self.writeFrame(Hub.sendSse, .{ event, json });
    }

    /// Writes through the Hub's per-connection lock when this connection is
    /// registered (so it can't interleave with a concurrent emitTo/heartbeat
    /// on the same socket); falls back to a direct write otherwise.
    fn writeFrame(self: *Sse, comptime writeFn: anytype, args: anytype) !void {
        self._hub.writeToConn(self._conn_id, writeFn, args) catch |err| switch (err) {
            error.UnknownConnection => return @call(.auto, writeFn, .{ self._hub, self._stream } ++ args),
            else => return err,
        };
    }

    /// Sends "retry: {ms}\n\n" — tells the client's EventSource how long to
    /// wait before reconnecting after a drop, overriding the browser default
    /// (~3s, unspecified by the SSE spec, so it varies). Safe to call more
    /// than once (e.g. to change it mid-connection); the client applies
    /// whatever the most recently received retry: field said.
    pub fn setRetry(self: *Sse, ms: u64) !void {
        try self.writeFrame(writeRetry, .{ms});
    }

    fn writeRetry(hub: *Hub, stream: net.Stream, ms: u64) !void {
        var write_buf: [64]u8 = undefined;
        var sw = net.Stream.Writer.init(stream, hub.io, &write_buf);
        const writer = &sw.interface;
        try writer.print("retry: {d}\n\n", .{ms});
        try writer.flush();
    }

    pub fn join(self: *Sse, channel: []const u8) !void {
        self.channel = channel;
        try self._hub.updateChannel(self._conn_id, channel);
    }

    /// join() plus replay: if the client reconnected with a Last-Event-ID
    /// header, immediately re-sends every event this channel recorded after
    /// that id (bounded history — see Hub.history_max_entries/_age_ms), so a
    /// dropped connection doesn't silently miss events between reconnects.
    /// No-op replay (just a plain join) if there's no Last-Event-ID header
    /// or nothing newer is in history.
    pub fn joinWithReplay(self: *Sse, channel: []const u8) !void {
        try self.join(channel);
        const last_id = self.lastEventId() orelse return;
        const entries = try self._hub.historySince(self.arena, channel, last_id);
        for (entries) |e| {
            try self.sendRaw(e.id, e.event, e.data);
        }
    }

    /// Adds `channel` to this connection's subscriptions, keeping the ones it
    /// already has (unlike join(), which replaces them). Lets one EventSource
    /// carry several channels — browsers cap HTTP/1.1 connections per origin
    /// at 6, so one EventSource per channel per tab runs out after a few tabs.
    pub fn subscribe(self: *Sse, channel: []const u8) !void {
        try self._hub.addChannel(self._conn_id, channel);
        if (self.channel.len == 0) self.channel = channel;
    }

    /// subscribe() to every channel, then replay what the client missed
    /// across all of them (Last-Event-ID is hub-wide, so one id covers every
    /// channel), in the original emit order.
    pub fn subscribeWithReplay(self: *Sse, channels: []const []const u8) !void {
        for (channels) |ch| try self.subscribe(ch);
        const last_id = self.lastEventId() orelse return;

        var all: std.ArrayListUnmanaged(Hub.HistoryEntry) = .empty;
        for (channels) |ch| {
            try all.appendSlice(self.arena, try self._hub.historySince(self.arena, ch, last_id));
        }
        std.mem.sort(Hub.HistoryEntry, all.items, {}, struct {
            fn lt(_: void, a: Hub.HistoryEntry, b: Hub.HistoryEntry) bool {
                return a.id < b.id;
            }
        }.lt);
        for (all.items) |e| try self.sendRaw(e.id, e.event, e.data);
    }

    pub fn joinUser(self: *Sse, user_id: u64) !void {
        // Must outlive this call — join() stores the slice on self.channel
        // and in the Hub's connection list for the connection's whole
        // lifetime. A stack buffer here would leave both as dangling slices
        // the moment this function returns (caught by a hanging test: the
        // Hub compares garbage bytes against a freshly-built channel name
        // and never finds a match, so nothing is ever delivered).
        const channel = try std.fmt.allocPrint(self.arena, "user:{d}", .{user_id});
        try self.join(channel);
    }

    pub fn param(self: *Sse, key: []const u8) ?[]const u8 {
        return self.params.get(key);
    }

    /// Case-insensitive lookup, mirroring Ctx.header() — headers are copied
    /// into Sse at handshake time (buildHandler), same as .params already is.
    pub fn header(self: *Sse, name: []const u8) ?[]const u8 {
        var iter = self.headers.iterator();
        while (iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) {
                return entry.value_ptr.*;
            }
        }
        return null;
    }

    /// Mirrors Ctx.cookie()'s exact parsing — same Cookie header format.
    pub fn cookie(self: *Sse, name: []const u8) ?[]const u8 {
        const cookie_header = self.header("Cookie") orelse return null;
        var it = std.mem.splitScalar(u8, cookie_header, ';');
        while (it.next()) |pair| {
            const trimmed = std.mem.trim(u8, pair, " ");
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
                const key = std.mem.trim(u8, trimmed[0..eq], " ");
                if (std.mem.eql(u8, key, name)) {
                    return std.mem.trim(u8, trimmed[eq + 1 ..], " ");
                }
            }
        }
        return null;
    }

    /// The Last-Event-ID header the browser sends automatically on
    /// reconnect, once it has seen at least one "id:" line — null if absent
    /// or not a valid integer.
    pub fn lastEventId(self: *Sse) ?u64 {
        const raw = self.header("Last-Event-ID") orelse return null;
        return std.fmt.parseInt(u64, raw, 10) catch null;
    }

    /// Writes a pre-formatted "id: N\nevent: X\ndata: Y\n\n" frame — used by
    /// joinWithReplay() to resend history entries verbatim (already-recorded
    /// event/data strings, not re-serialized).
    fn sendRaw(self: *Sse, id: u64, event: []const u8, data: []const u8) !void {
        try self.writeFrame(Hub.sendSseWithId, .{ id, event, data });
    }

    pub fn wait(self: *Sse) void {
        var buf: [1]u8 = undefined;
        var read_buf: [256]u8 = undefined;
        var reader = net.Stream.Reader.init(self._stream, self.io, &read_buf);
        _ = reader.interface.readSliceAll(&buf) catch {};
    }
};

// Shared by Server.sse() and Group.sse() — kept here (not in core/app.zig)
// so routing/group.zig can use it without importing app.zig, which would
// create a circular import (app.zig already imports group.zig for
// mount()'s parameter type).
pub fn buildHandler(comptime handler: fn (*Sse) anyerror!void) Handler {
    const W = struct {
        pub fn call(ctx: *Ctx) anyerror!Response {
            const hub = ctx._sse_hub orelse return ctx.text("", .{});

            var write_buf: [512]u8 = undefined;
            var sw = net.Stream.Writer.init(ctx._stream, ctx._io, &write_buf);
            const writer = &sw.interface;
            try writer.writeAll(
                "HTTP/1.1 200 OK\r\n" ++
                    "Content-Type: text/event-stream\r\n" ++
                    "Cache-Control: no-cache\r\n" ++
                    "Connection: keep-alive\r\n" ++
                    "Access-Control-Allow-Origin: *\r\n" ++
                    "\r\n",
            );
            try writer.flush();

            var rand_buf: [8]u8 = undefined;
            std.Io.random(ctx._io, &rand_buf);
            const conn_id = std.mem.readInt(u64, &rand_buf, .little);

            try hub.add(.{
                .id = conn_id,
                .stream = ctx._stream,
                .type = .sse,
            });
            defer hub.remove(conn_id);

            var sse = Sse{
                ._stream = ctx._stream,
                ._hub = hub,
                ._conn_id = conn_id,
                .params = ctx.params,
                .headers = ctx._headers,
                .arena = ctx.arena,
                .io = ctx._io,
            };

            // Sensible default so the browser's EventSource doesn't fall back
            // to its own unspecified (~3s) reconnect delay; apps can override
            // via sse.setRetry(ms) before/after this from within `handler`.
            sse.setRetry(Hub.default_retry_ms) catch {};

            handler(&sse) catch {};
            return Response{ .raw = true };
        }
    };
    return W.call;
}

// =============================================================================
// Tests
// =============================================================================
// Sse itself had zero coverage before this — Hub (hub.zig) already had a
// decent suite for join/broadcast/emit/remove at the connection-list level,
// but nothing exercised the Sse wrapper methods (send/join/joinUser/param)
// directly. These construct a Sse by hand (not through buildHandler, which
// needs a full Ctx/HTTP handshake) over a real socketpair, mirroring the
// pattern hub.zig's own tests already use.

const testing = std.testing;

fn makeSocketPair() ![2]net.Socket {
    var fds: [2]posix.fd_t = undefined;
    const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
    if (rc != 0) return error.Unexpected;
    return .{
        net.Socket{ .handle = fds[0], .address = .{ .ip4 = .{ .bytes = [4]u8{ 0, 0, 0, 0 }, .port = 0 } } },
        net.Socket{ .handle = fds[1], .address = .{ .ip4 = .{ .bytes = [4]u8{ 0, 0, 0, 0 }, .port = 0 } } },
    };
}

// ── Baseline: current behavior (send/join/joinUser/param) ──────────────────

test "Sse: send writes 'event: X\\ndata: Y\\n\\n' wire format" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[0].close(io);
    defer sockets[1].close(io);

    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var sse = Sse{
        ._stream = .{ .socket = sockets[0] },
        ._hub = &hub,
        ._conn_id = 1,
        .arena = arena.allocator(),
        .io = io,
    };

    try sse.send("greeting", .{ .msg = "hi" });

    const expected = "event: greeting\ndata: {\"msg\":\"hi\"}\n\n";
    var buf: [expected.len]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualStrings(expected, &buf);
}

test "Sse: join updates the connection's channel on the Hub" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // sockets[0] is handed to the Hub below and stays registered for the
    // whole test — Hub.deinit() closes it, so closing it again here would
    // double-close (crashes as EBADF in debug builds).
    defer sockets[1].close(io);

    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .type = .sse });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var sse = Sse{
        ._stream = .{ .socket = sockets[0] },
        ._hub = &hub,
        ._conn_id = 1,
        .arena = arena.allocator(),
        .io = io,
    };

    try sse.join("room:42");
    try testing.expectEqualStrings("room:42", sse.channel);

    // Confirms the Hub-side channel really updated, not just the local field —
    // emitTo("room:42", ...) must actually reach this connection now.
    hub.emitTo("room:42", "notice", .{ .text = "hi" });

    // emitTo() now prefixes every channel event with "id: N\n" (incrementing
    // per channel) ahead of "event: ".
    const expected = "id: 1\nevent: ";
    var buf: [expected.len]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualStrings(expected, &buf);
}

test "Sse: join to a different channel does not receive emitTo on the old one" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // sockets[0] stays Hub-registered — see the send-format test above.
    defer sockets[1].close(io);

    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .channel = "room:old", .type = .sse });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var sse = Sse{
        ._stream = .{ .socket = sockets[0] },
        ._hub = &hub,
        ._conn_id = 1,
        .channel = "room:old",
        .arena = arena.allocator(),
        .io = io,
    };

    try sse.join("room:new");

    // Nothing should arrive on the old channel anymore.
    hub.emitTo("room:old", "should-not-arrive", .{});
    try (net.Stream{ .socket = sockets[0] }).shutdown(io, .send);
}

test "Sse: joinUser joins the 'user:{id}' channel" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // sockets[0] is handed to the Hub below and stays registered for the
    // whole test — Hub.deinit() closes it, so closing it again here would
    // double-close (crashes as EBADF in debug builds).
    defer sockets[1].close(io);

    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .type = .sse });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var sse = Sse{
        ._stream = .{ .socket = sockets[0] },
        ._hub = &hub,
        ._conn_id = 1,
        .arena = arena.allocator(),
        .io = io,
    };

    try sse.joinUser(99);
    try testing.expectEqualStrings("user:99", sse.channel);

    hub.notifyUser(99, "private", .{});

    // notifyUser() routes through emitTo(), which now prefixes every channel
    // event with "id: N\n" ahead of "event: ".
    const expected = "id: 1\nevent: ";
    var buf: [expected.len]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualStrings(expected, &buf);
}

test "Sse: param returns the value for a known key and null for an unknown one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    var params: std.StringHashMapUnmanaged([]const u8) = .{};
    try params.put(arena.allocator(), "_auth_sub", "abc-123");

    var sse = Sse{
        ._stream = undefined,
        ._hub = &hub,
        ._conn_id = 1,
        .params = params,
        .arena = arena.allocator(),
        .io = io,
    };

    try testing.expectEqualStrings("abc-123", sse.param("_auth_sub").?);
    try testing.expectEqual(@as(?[]const u8, null), sse.param("condo_id"));
}

// ── id: field (was the TDD red spec, now implemented in Hub.emitTo) ────────

test "Sse: emitTo includes an incrementing id: line" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // sockets[0] stays Hub-registered — see the send-format test above.
    defer sockets[1].close(io);

    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .channel = "room:1", .type = .sse });

    hub.emitTo("room:1", "notice", .{ .text = "first" });
    hub.emitTo("room:1", "notice", .{ .text = "second" });

    var buf: [256]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);

    const expected_first = "id: 1\nevent: notice\ndata: {\"text\":\"first\"}\n\n";
    try reader.interface.readSliceAll(buf[0..expected_first.len]);
    try testing.expectEqualStrings(expected_first, buf[0..expected_first.len]);

    const expected_second = "id: 2\nevent: notice\ndata: {\"text\":\"second\"}\n\n";
    try reader.interface.readSliceAll(buf[0..expected_second.len]);
    try testing.expectEqualStrings(expected_second, buf[0..expected_second.len]);
}

// ── retry: field ─────────────────────────────────────────────────────────

test "Sse: setRetry writes a retry: line" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[0].close(io);
    defer sockets[1].close(io);

    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var sse = Sse{
        ._stream = .{ .socket = sockets[0] },
        ._hub = &hub,
        ._conn_id = 1,
        .arena = arena.allocator(),
        .io = io,
    };

    try sse.setRetry(5000);

    const expected = "retry: 5000\n\n";
    var buf: [expected.len]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualStrings(expected, &buf);
}

// ── Headers / cookies ────────────────────────────────────────────────────

fn testSseWithHeaders(hub: *Hub, arena: std.mem.Allocator, io: std.Io, pairs: []const [2][]const u8) !Sse {
    var headers: std.StringHashMapUnmanaged([]const u8) = .{};
    for (pairs) |p| try headers.put(arena, p[0], p[1]);
    return Sse{
        ._stream = undefined,
        ._hub = hub,
        ._conn_id = 1,
        .headers = headers,
        .arena = arena,
        .io = io,
    };
}

test "Sse: header is case-insensitive and returns null for unknown names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    var sse = try testSseWithHeaders(&hub, arena.allocator(), io, &.{
        .{ "Last-Event-ID", "42" },
    });

    try testing.expectEqualStrings("42", sse.header("last-event-id").?);
    try testing.expectEqualStrings("42", sse.header("Last-Event-ID").?);
    try testing.expectEqual(@as(?[]const u8, null), sse.header("X-Missing"));
}

test "Sse: cookie parses the Cookie header, mirroring Ctx.cookie()" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    var sse = try testSseWithHeaders(&hub, arena.allocator(), io, &.{
        .{ "Cookie", "orbitx_condo=abc; session=xyz" },
    });

    try testing.expectEqualStrings("abc", sse.cookie("orbitx_condo").?);
    try testing.expectEqualStrings("xyz", sse.cookie("session").?);
    try testing.expectEqual(@as(?[]const u8, null), sse.cookie("missing"));
}

test "Sse: cookie returns null when there is no Cookie header at all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    var sse = try testSseWithHeaders(&hub, arena.allocator(), io, &.{});
    try testing.expectEqual(@as(?[]const u8, null), sse.cookie("anything"));
}

test "Sse: lastEventId parses Last-Event-ID as an integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    var sse = try testSseWithHeaders(&hub, arena.allocator(), io, &.{
        .{ "Last-Event-ID", "7" },
    });
    try testing.expectEqual(@as(?u64, 7), sse.lastEventId());
}

test "Sse: lastEventId is null when the header is missing or not a number" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    var missing = try testSseWithHeaders(&hub, arena.allocator(), io, &.{});
    try testing.expectEqual(@as(?u64, null), missing.lastEventId());

    var invalid = try testSseWithHeaders(&hub, arena.allocator(), io, &.{
        .{ "Last-Event-ID", "not-a-number" },
    });
    try testing.expectEqual(@as(?u64, null), invalid.lastEventId());
}

// ── joinWithReplay (Last-Event-ID replay) ───────────────────────────────

test "Sse: joinWithReplay resends only events missed since Last-Event-ID" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    // Two events happen on the channel before this connection ever joins —
    // as if a previous connection on the same channel had already seen id 1.
    hub.emitTo("room:1", "a", .{ .n = 1 });
    hub.emitTo("room:1", "b", .{ .n = 2 });

    const sockets = try makeSocketPair();
    // sockets[0] becomes Hub-registered inside joinWithReplay -> join() below.
    defer sockets[1].close(io);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var headers: std.StringHashMapUnmanaged([]const u8) = .{};
    try headers.put(arena.allocator(), "Last-Event-ID", "1");

    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .type = .sse });
    var sse = Sse{
        ._stream = .{ .socket = sockets[0] },
        ._hub = &hub,
        ._conn_id = 1,
        .headers = headers,
        .arena = arena.allocator(),
        .io = io,
    };

    try sse.joinWithReplay("room:1");

    // Only event "b" (id 2) should have been replayed — id 1 is already
    // known to the client per its own Last-Event-ID.
    const expected = "id: 2\nevent: b\ndata: {\"n\":2}\n\n";
    var buf: [expected.len]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualStrings(expected, &buf);
}

test "Sse: joinWithReplay without a Last-Event-ID header just joins, no replay" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    hub.emitTo("room:1", "a", .{ .n = 1 });

    const sockets = try makeSocketPair();
    // sockets[0] becomes Hub-registered below — see "Hub: add increases
    // count" in hub.zig for why it must not also get its own defer close.
    defer sockets[1].close(io);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .type = .sse });
    var sse = Sse{
        ._stream = .{ .socket = sockets[0] },
        ._hub = &hub,
        ._conn_id = 1,
        .arena = arena.allocator(),
        .io = io,
    };

    try sse.joinWithReplay("room:1");
    try testing.expectEqualStrings("room:1", sse.channel);

    // Nothing should have been sent — confirm without blocking forever.
    try (net.Stream{ .socket = sockets[0] }).shutdown(io, .send);
}

// ── subscribe / subscribeWithReplay ─────────────────────────────────────

test "Sse: subscribe keeps previous channels, join replaces them" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .type = .sse });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sse = Sse{ ._stream = .{ .socket = sockets[0] }, ._hub = &hub, ._conn_id = 1, .arena = arena.allocator(), .io = io };

    try sse.subscribe("condo:1");
    try sse.subscribe("user:2");
    try testing.expectEqual(@as(usize, 1), hub.channelCount("condo:1"));
    try testing.expectEqual(@as(usize, 1), hub.channelCount("user:2"));

    try sse.join("only");
    try testing.expectEqual(@as(usize, 0), hub.channelCount("condo:1"));
    try testing.expectEqual(@as(usize, 0), hub.channelCount("user:2"));
    try testing.expectEqual(@as(usize, 1), hub.channelCount("only"));
}

test "Sse: subscribeWithReplay replays missed events from all channels in emit order" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    hub.emitTo("condo:1", "c1", .{ .k = 1 }); // id 1 (client already saw it)
    hub.emitTo("user:2", "u1", .{ .k = 1 }); // id 2
    hub.emitTo("other", "x", .{ .k = 1 }); // id 3, not subscribed
    hub.emitTo("condo:1", "c2", .{ .k = 1 }); // id 4

    const sockets = try makeSocketPair();
    defer sockets[1].close(io);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var headers: std.StringHashMapUnmanaged([]const u8) = .{};
    try headers.put(arena.allocator(), "Last-Event-ID", "1");
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .type = .sse });
    var sse = Sse{ ._stream = .{ .socket = sockets[0] }, ._hub = &hub, ._conn_id = 1, .headers = headers, .arena = arena.allocator(), .io = io };

    try sse.subscribeWithReplay(&.{ "condo:1", "user:2" });

    const expected = "id: 2\nevent: u1\ndata: {\"k\":1}\n\nid: 4\nevent: c2\ndata: {\"k\":1}\n\n";
    var buf: [expected.len]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualStrings(expected, &buf);
}

test "Sse: setRetry and send go through the hub lock when registered" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 7, .stream = .{ .socket = sockets[0] }, .type = .sse });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sse = Sse{ ._stream = .{ .socket = sockets[0] }, ._hub = &hub, ._conn_id = 7, .arena = arena.allocator(), .io = io };

    try sse.setRetry(1500);
    try sse.send("hi", .{ .a = 1 });
    const expected = "retry: 1500\n\nevent: hi\ndata: {\"a\":1}\n\n";
    var buf: [expected.len]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualStrings(expected, &buf);
}
