//! `spider.Hub`: the open SSE and WebSocket connections of the server and the
//! channels they joined. Handlers and jobs use it to send to everyone, to a
//! channel or to one user; the server registers and removes the connections.

const std = @import("std");
const posix = std.posix;
const net = std.Io.net;
const Watchdog = @import("../core/watchdog.zig").Watchdog;

/// The open connections of the app and the channels they joined. The server
/// owns its hubs: one for every SSE route together (`c.sseHub()`, and the hub
/// a `spider.every` job receives), and one for each WebSocket route (what
/// `Ws.broadcast` sends through, and what a `Server.wsInterval` callback
/// receives).
///
/// ```zig
/// hub.emitTo(channel, "package_updated", .{ .id = pkg.id });
/// ```
///
/// Who receives what:
///
///   - `emit`: every SSE connection.
///   - `emitTo`, `emitHtmlTo`: the SSE connections on one channel; recorded
///     for replay.
///   - `notifyUser`: the SSE connections on the channel `user:<id>`.
///   - `broadcast`, `broadcastFmt`: every connection, SSE and WebSocket.
///   - `broadcastToChannel`, `broadcastToChannelFmt`: the connections on one
///     channel, SSE and WebSocket.
///
/// None of them returns an error: a connection whose write fails is taken out
/// of the hub and its socket shut down, and the others still get the message.
/// The fields belong to the server; use the methods.
pub const Hub = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    connections: std.ArrayListUnmanaged(*ConnectionSlot) = .empty,
    channel_history: std.StringHashMapUnmanaged(ChannelHistory) = .empty,
    /// Hub-wide event id counter (guarded by `mutex`). Global rather than per
    /// channel so one connection subscribed to several channels still gets a
    /// single, unambiguous Last-Event-ID to resume from.
    next_event_id: u64 = 1,

    heartbeat_thread: ?std.Thread = null,
    heartbeat_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    sweep_thread: ?std.Thread = null,
    sweep_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Longest one write to a client may block (its socket buffer full:
    /// it stopped reading) before the connection is dropped. 0 = unbounded.
    /// Server.listen() sets it from Config.stream_write_timeout_ms; only
    /// connections registered with a `watch` entry are bounded.
    write_timeout_ms: u32 = 0,

    /// The interval of `Server.sseHeartbeat(null)`: 30 seconds.
    pub const default_heartbeat_ms: u64 = 30_000;
    /// The interval of `Server.sseSweep(null)`: 60 seconds.
    pub const default_sweep_ms: u64 = 60_000;
    /// The reconnection delay every SSE stream announces when it opens: 3
    /// seconds. `Sse.setRetry` changes it for one connection.
    pub const default_retry_ms: u64 = 3_000;
    /// Per-channel replay buffer bound — whichever limit is hit first.
    const history_max_entries: usize = 50;
    const history_max_age_ms: i64 = 5 * 60 * 1000;

    // internal: what the server registers for each SSE or WebSocket connection.
    pub const Connection = struct {
        id: u64,
        stream: net.Stream,
        channel: []const u8 = "",
        namespace: []const u8 = "",
        type: enum { ws, sse } = .ws,
        last_activity: ?std.Io.Timestamp = null,
        /// The connection's watchdog entry, used to bound hub writes.
        watch: ?*Watchdog.Entry = null,
    };

    /// Heap-allocated (stable address) so a broadcast/heartbeat/sweep
    /// snapshot can hold a *pointer* to it instead of copying `Connection`
    /// by value. That matters because io_mutex must be the SAME lock
    /// instance for every holder — a copy would be a distinct, useless
    /// lock that excludes nothing. io_mutex is what makes "close this
    /// connection" (remove()) and "write to this connection" (any single
    /// broadcast/heartbeat/sweep call) mutually exclusive for THIS
    /// connection specifically, without requiring the Hub's global
    /// `mutex` to stay held during socket I/O (which would stall every
    /// other connection behind one slow/stuck client).
    ///
    /// io_mutex alone isn't enough, though: broadcast(), emitTo(),
    /// sendHeartbeats() and sweepDeadConnections() can all be running
    /// concurrently, each with its OWN snapshot that may include the SAME
    /// slot. io_mutex only keeps one writer and remove() from touching the
    /// fd at the same time — it says nothing about whether some OTHER
    /// concurrent snapshot still holds a pointer to this slot when remove()
    /// is done with it. refs answers that: every snapshot that picks up
    /// this slot bumps it (under the Hub's global mutex, alongside
    /// remove()'s own decrement, so the count itself never races), and
    /// whichever side's release drops it to zero is the one that actually
    /// frees the memory. remove()'s own reference to the slot (the one the
    /// connections list itself holds) counts as 1 from creation.
    const ConnectionSlot = struct {
        conn: Connection,
        io_mutex: std.Io.Mutex = .init,
        closed: std.atomic.Value(bool) = .init(false),
        refs: std.atomic.Value(usize) = .init(1),
        /// Channels added with subscribe() on top of `conn.channel` (owned,
        /// hub allocator; guarded by the Hub's `mutex`).
        extra_channels: std.ArrayListUnmanaged([]const u8) = .empty,

        fn inChannel(slot: *const ConnectionSlot, channel: []const u8) bool {
            if (std.mem.eql(u8, slot.conn.channel, channel)) return true;
            for (slot.extra_channels.items) |ch| {
                if (std.mem.eql(u8, ch, channel)) return true;
            }
            return false;
        }

        fn clearExtra(slot: *ConnectionSlot, allocator: std.mem.Allocator) void {
            for (slot.extra_channels.items) |ch| allocator.free(ch);
            slot.extra_channels.deinit(allocator);
            slot.extra_channels = .empty;
        }
    };

    /// One event recorded for replay, as `historySince` returns it. `id` is the
    /// hub-wide event id sent to the clients; `data` is the text that went out
    /// (JSON from `emitTo`, HTML from `emitHtmlTo`).
    pub const HistoryEntry = struct {
        id: u64,
        event: []const u8,
        data: []const u8,
        timestamp: std.Io.Timestamp,
    };

    const ChannelHistory = struct {
        entries: std.ArrayListUnmanaged(HistoryEntry) = .empty,

        fn deinit(self: *ChannelHistory, allocator: std.mem.Allocator) void {
            for (self.entries.items) |e| {
                allocator.free(e.event);
                allocator.free(e.data);
            }
            self.entries.deinit(allocator);
        }
    };

    /// A hub with no connections. Its writes go through `io`, which must be the
    /// Io of the server that owns the sockets. The server creates the hubs of an
    /// app; a test may create its own.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) Hub {
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = std.Io.Mutex.init,
            .connections = .empty,
        };
    }

    /// Stops the heartbeat and sweep threads, closes the stream of every
    /// connection still registered and frees what the hub allocated.
    pub fn deinit(self: *Hub) void {
        self.stopHeartbeat();
        self.stopSweep();

        for (self.connections.items) |slot| {
            slot.conn.stream.close(self.io);
            self.releaseSlot(slot);
        }
        self.connections.deinit(self.allocator);

        var it = self.channel_history.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.channel_history.deinit(self.allocator);
    }

    // internal: the server registers each connection before running its handler.
    // `error.DuplicateId` when the id is already registered. `conn.channel` is not copied.
    pub fn add(self: *Hub, conn: Connection) !void {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);
        for (self.connections.items) |slot| {
            if (slot.conn.id == conn.id) return error.DuplicateId;
        }
        const slot = try self.allocator.create(ConnectionSlot);
        errdefer self.allocator.destroy(slot);
        slot.* = .{ .conn = conn };
        slot.conn.last_activity = self.now();
        try self.connections.append(self.allocator, slot);
    }

    // internal: handlers call `Sse.join` / `Ws.join`, which know the connection id.
    // Moves the connection to `channel`, dropping every other subscription.
    pub fn updateChannel(self: *Hub, conn_id: u64, channel: []const u8) !void {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);
        for (self.connections.items) |slot| {
            if (slot.conn.id == conn_id) {
                slot.conn.channel = channel;
                slot.clearExtra(self.allocator);
                return;
            }
        }
    }

    // internal: handlers call `Sse.subscribe`, which knows the connection id.
    // Adds `channel` to the connection's subscriptions, keeping the ones it
    // already has — one SSE connection can then serve several channels
    // (e.g. "condo:X" + "user:Y") instead of the browser opening one
    // EventSource per channel. No-op if already subscribed.
    pub fn addChannel(self: *Hub, conn_id: u64, channel: []const u8) !void {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);
        for (self.connections.items) |slot| {
            if (slot.conn.id != conn_id) continue;
            if (slot.inChannel(channel)) return;
            const owned = try self.allocator.dupe(u8, channel);
            errdefer self.allocator.free(owned);
            try slot.extra_channels.append(self.allocator, owned);
            return;
        }
        return error.UnknownConnection;
    }

    /// Number of live connections subscribed to `channel`.
    pub fn channelCount(self: *Hub, channel: []const u8) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        var n: usize = 0;
        for (self.connections.items) |slot| {
            if (slot.inChannel(channel)) n += 1;
        }
        return n;
    }

    // internal: the server removes a connection when its handler returns.
    // Removes the connection from the list (so no future broadcast/
    // heartbeat/sweep snapshot can find it), waiting on io_mutex first
    // to make sure no in-flight write is currently using it. That wait
    // happens *after* releasing the Hub's global `mutex`, so a
    // slow-to-finish write on this one connection can't stall
    // add()/remove()/broadcast() calls for any other connection.
    //
    // Does NOT close conn.stream — every caller (buildHandler for both
    // SSE and WS, in sse.zig/app.zig) registers the connection from
    // inside a Handler that's already running under handleConnection's
    // own `defer ctx.stream.close(ctx.io)`, which is what actually owns
    // and closes the fd once the handler returns. Closing it here too
    // used to double-close: the first close() releases the fd number
    // back to the OS, which can immediately hand that same number to a
    // brand new connection — and the second close() (or a concurrent
    // recv() on that new connection racing it) then hits the wrong
    // socket. The io_mutex wait below is what remove() actually needs to
    // provide: proof that no write is touching the stream right now,
    // before handleConnection's defer is allowed to close it for real.
    pub fn remove(self: *Hub, conn_id: u64) void {
        const slot = blk: {
            self.mutex.lock(self.io) catch return;
            defer self.mutex.unlock(self.io);
            for (self.connections.items, 0..) |slot, i| {
                if (slot.conn.id == conn_id) {
                    _ = self.connections.orderedRemove(i);
                    break :blk slot;
                }
            }
            return;
        };

        slot.io_mutex.lock(self.io) catch {
            self.releaseSlot(slot);
            return;
        };
        slot.closed.store(true, .release);
        slot.io_mutex.unlock(self.io);
        self.releaseSlot(slot);
    }

    /// Number of connections registered in this hub, whatever their channel.
    pub fn count(self: *Hub) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        return self.connections.items.len;
    }

    /// Drops one reference (see ConnectionSlot's doc comment) and frees
    /// the slot if that was the last one. Every snapshot that picks up a
    /// slot must eventually call this exactly once for it; remove() calls
    /// it once too, for the connections list's own original reference.
    fn releaseSlot(self: *Hub, slot: *ConnectionSlot) void {
        if (slot.refs.fetchSub(1, .release) == 1) {
            slot.clearExtra(self.allocator);
            self.allocator.destroy(slot);
        }
    }

    // internal: how `Sse` writes to its own connection.
    // Writes to ONE registered connection under its io_mutex, so a direct
    // write (Sse.send, replay) can never interleave its bytes with a
    // concurrent Hub broadcast/heartbeat to the same socket.
    // error.UnknownConnection when `conn_id` isn't registered.
    pub fn writeToConn(self: *Hub, conn_id: u64, comptime writeFn: anytype, args: anytype) !void {
        const slot = blk: {
            self.mutex.lock(self.io) catch return error.LockFailed;
            defer self.mutex.unlock(self.io);
            for (self.connections.items) |slot| {
                if (slot.conn.id == conn_id) {
                    _ = slot.refs.fetchAdd(1, .monotonic);
                    break :blk slot;
                }
            }
            return error.UnknownConnection;
        };
        defer self.releaseSlot(slot);
        return self.writeToSlot(slot, writeFn, args);
    }

    /// Runs `writeFn(self, slot.conn.stream, ...args)` while holding
    /// slot's own io_mutex — never races remove()'s close() for THIS
    /// connection, without needing the Hub's global `mutex` held during
    /// the write. error.AlreadyClosed means remove() got there first
    /// (the connection is simply gone, not a failed write — callers
    /// should not treat this as "dead" and try to remove it again).
    /// Does NOT release the caller's reference on `slot` — the caller
    /// (whoever built the snapshot) still owns that and must call
    /// releaseSlot() itself once done with it.
    fn writeToSlot(self: *Hub, slot: *ConnectionSlot, comptime writeFn: anytype, args: anytype) !void {
        slot.io_mutex.lock(self.io) catch return error.LockFailed;
        defer slot.io_mutex.unlock(self.io);
        if (slot.closed.load(.acquire)) return error.AlreadyClosed;
        // A client that stopped reading would block this write forever
        // (and every broadcast behind it): past write_timeout_ms the
        // watchdog shuts the socket down and the write fails.
        if (slot.conn.watch) |w| if (self.write_timeout_ms != 0) w.armWrite(self.write_timeout_ms);
        defer if (slot.conn.watch) |w| w.disarm();
        return @call(.auto, writeFn, .{ self, slot.conn.stream } ++ args);
    }

    // internal: what the hub does with a connection whose write failed.
    // A write to this connection failed (or timed out): unregister it AND
    // shut its socket down. Unregistering alone left the client connected
    // to a stream that never got another event — its handler kept waiting
    // on the open socket, so the browser never reconnected. The shutdown
    // wakes that handler; handleConnection then closes the fd as usual.
    // Only done while the slot isn't closed yet, under its io_mutex: the
    // handler's own remove() sets `closed` before the fd can be closed, so
    // the descriptor shut down here is still this connection's.
    pub fn drop(self: *Hub, conn_id: u64) void {
        const slot = blk: {
            self.mutex.lock(self.io) catch return;
            defer self.mutex.unlock(self.io);
            for (self.connections.items) |slot| {
                if (slot.conn.id == conn_id) {
                    _ = slot.refs.fetchAdd(1, .monotonic);
                    break :blk slot;
                }
            }
            return;
        };
        defer self.releaseSlot(slot);
        if (slot.io_mutex.lock(self.io)) |_| {
            if (!slot.closed.load(.acquire)) _ = std.c.shutdown(slot.conn.stream.socket.handle, std.c.SHUT.RDWR);
            slot.io_mutex.unlock(self.io);
        } else |_| {}
        self.remove(conn_id);
    }

    /// Adds `slot` to a broadcast/heartbeat/sweep snapshot, taking a
    /// reference for it (ConnectionSlot.refs). Must be called while still
    /// holding the Hub's global `mutex` — the same lock add()/remove() use
    /// around their own refs changes, so the count itself never races.
    /// Every slot appended this way must get exactly one releaseSlot()
    /// call back once the caller is done with it.
    fn snapshotAppend(self: *Hub, snapshot: *std.ArrayListUnmanaged(*ConnectionSlot), slot: *ConnectionSlot) void {
        snapshot.append(self.allocator, slot) catch return;
        _ = slot.refs.fetchAdd(1, .monotonic);
    }

    /// Sends `message` to every connection of the hub, whatever its channel. A
    /// WebSocket client receives it as a text frame; an SSE client as an event
    /// named `message` with the text as data. Not recorded for replay.
    pub fn broadcast(self: *Hub, message: []const u8) void {
        self.mutex.lock(self.io) catch return;
        var snapshot: std.ArrayListUnmanaged(*ConnectionSlot) = .empty;
        defer snapshot.deinit(self.allocator);
        for (self.connections.items) |slot| {
            self.snapshotAppend(&snapshot, slot);
        }
        self.mutex.unlock(self.io);

        for (snapshot.items) |slot| {
            const failed = switch (slot.conn.type) {
                .ws => self.writeToSlot(slot, sendText, .{message}),
                .sse => self.writeToSlot(slot, sendSse, .{ "message", message }),
            };
            failed catch |err| {
                if (err != error.AlreadyClosed) self.drop(slot.conn.id);
            };
            self.releaseSlot(slot);
        }
    }

    /// Sends to one user: `emitTo` on the channel `user:<user_id>`, the one a
    /// stream joins with `Sse.joinUser(user_id)`. Only SSE connections receive
    /// it.
    pub fn notifyUser(self: *Hub, user_id: u64, event: []const u8, data: anytype) void {
        var ch_buf: [32]u8 = undefined;
        const channel = std.fmt.bufPrint(&ch_buf, "user:{d}", .{user_id}) catch return;
        self.emitTo(channel, event, data);
    }

    /// Sends the event `event`, with `data` as JSON, to every SSE connection of
    /// the hub, whatever its channel. WebSocket connections do not receive it.
    /// It carries no event id and is not recorded for replay. Nothing is sent
    /// when `data` cannot be serialized.
    ///
    /// ```zig
    /// c.sseHub().emit("post_created", .{ .id = id });
    /// ```
    pub fn emit(self: *Hub, event: []const u8, data: anytype) void {
        const json = std.json.Stringify.valueAlloc(self.allocator, data, .{}) catch return;
        defer self.allocator.free(json);
        self.broadcastEvent(event, json);
    }

    /// Sends the event `event`, with `data` as JSON, to the SSE connections
    /// subscribed to `channel` (`Sse.join`, `Sse.subscribe`). WebSocket
    /// connections do not receive it. The event gets the next hub-wide id and is
    /// recorded in the channel's history (the last 50 events, at most 5 minutes
    /// old), so a client that reconnects gets what it missed (`Sse.joinWithReplay`).
    /// It is recorded even when nobody is on the channel. Nothing is sent when
    /// `data` cannot be serialized.
    ///
    /// ```zig
    /// hub.emitTo(channel, "notification_created", .{});
    /// ```
    pub fn emitTo(self: *Hub, channel: []const u8, event: []const u8, data: anytype) void {
        const json = std.json.Stringify.valueAlloc(self.allocator, data, .{}) catch return;
        defer self.allocator.free(json);
        const id = self.recordHistory(channel, event, json) catch return;
        self.broadcastToChannelEvent(channel, id, event, json);
    }

    /// emitTo() for HTML: `html` goes out as is (not JSON-encoded), one
    /// `data:` line per line, so htmx's SSE extension can swap it in
    /// (`<div hx-ext="sse" sse-connect="/events" sse-swap="badge">`).
    /// Recorded in the channel's history like emitTo(). Render it once for
    /// everyone on the channel: it must not carry per-user data.
    pub fn emitHtmlTo(self: *Hub, channel: []const u8, event: []const u8, html: []const u8) void {
        const id = self.recordHistory(channel, event, html) catch return;
        self.broadcastToChannelEvent(channel, id, event, html);
    }

    /// Assigns the next hub-wide event id and appends
    /// the event to its replay buffer, pruning anything past
    /// history_max_entries or history_max_age_ms. Only emitTo()/notifyUser()
    /// go through here — emit()/broadcast() aren't channel-scoped, so there's
    /// no natural history bucket for them, and Sse.send() is a raw one-off
    /// write to a single connection, not routed through the Hub at all.
    fn recordHistory(self: *Hub, channel: []const u8, event: []const u8, data: []const u8) !u64 {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);

        const gop = try self.channel_history.getOrPut(self.allocator, channel);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, channel);
            gop.value_ptr.* = .{};
        }
        const hist = gop.value_ptr;
        const id = self.next_event_id;
        self.next_event_id += 1;

        const ts = self.now();
        try hist.entries.append(self.allocator, .{
            .id = id,
            .event = try self.allocator.dupe(u8, event),
            .data = try self.allocator.dupe(u8, data),
            .timestamp = ts,
        });

        while (hist.entries.items.len > history_max_entries) {
            const old = hist.entries.orderedRemove(0);
            self.allocator.free(old.event);
            self.allocator.free(old.data);
        }
        while (hist.entries.items.len > 0 and
            hist.entries.items[0].timestamp.durationTo(ts).toMilliseconds() > history_max_age_ms)
        {
            const old = hist.entries.orderedRemove(0);
            self.allocator.free(old.event);
            self.allocator.free(old.data);
        }

        return id;
    }

    /// Copies (caller-owned via `allocator`) every history entry recorded
    /// for `channel` with id > last_id, in order — what Sse.joinWithReplay()
    /// sends on reconnect. Empty slice if the channel has no history or
    /// last_id is already caught up.
    pub fn historySince(self: *Hub, allocator: std.mem.Allocator, channel: []const u8, last_id: u64) ![]HistoryEntry {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);

        const hist = self.channel_history.getPtr(channel) orelse return &.{};
        var out: std.ArrayListUnmanaged(HistoryEntry) = .empty;
        for (hist.entries.items) |e| {
            if (e.id > last_id) {
                try out.append(allocator, .{
                    .id = e.id,
                    .event = try allocator.dupe(u8, e.event),
                    .data = try allocator.dupe(u8, e.data),
                    .timestamp = e.timestamp,
                });
            }
        }
        return out.toOwnedSlice(allocator);
    }

    fn broadcastEvent(self: *Hub, event: []const u8, data: []const u8) void {
        self.mutex.lock(self.io) catch return;
        var snapshot: std.ArrayListUnmanaged(*ConnectionSlot) = .empty;
        defer snapshot.deinit(self.allocator);
        for (self.connections.items) |slot| {
            if (slot.conn.type == .sse) {
                self.snapshotAppend(&snapshot, slot);
            }
        }
        self.mutex.unlock(self.io);

        for (snapshot.items) |slot| {
            self.writeToSlot(slot, sendSse, .{ event, data }) catch |err| {
                if (err != error.AlreadyClosed) self.drop(slot.conn.id);
            };
            self.releaseSlot(slot);
        }
    }

    fn broadcastToChannelEvent(self: *Hub, channel: []const u8, id: u64, event: []const u8, data: []const u8) void {
        self.mutex.lock(self.io) catch return;
        var snapshot: std.ArrayListUnmanaged(*ConnectionSlot) = .empty;
        defer snapshot.deinit(self.allocator);
        for (self.connections.items) |slot| {
            if (slot.conn.type == .sse and slot.inChannel(channel)) {
                self.snapshotAppend(&snapshot, slot);
            }
        }
        self.mutex.unlock(self.io);

        for (snapshot.items) |slot| {
            self.writeToSlot(slot, sendSseWithId, .{ id, event, data }) catch |err| {
                if (err != error.AlreadyClosed) self.drop(slot.conn.id);
            };
            self.releaseSlot(slot);
        }
    }

    /// `broadcast` with a formatted message: every connection of the hub.
    pub fn broadcastFmt(self: *Hub, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(msg);
        self.broadcast(msg);
    }

    /// `broadcastToChannel` with a formatted message: the connections on `channel`.
    pub fn broadcastToChannelFmt(self: *Hub, channel: []const u8, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(msg);
        self.broadcastToChannel(channel, msg);
    }

    /// Sends `message` to the connections on `channel`, SSE and WebSocket alike:
    /// a text frame for a WebSocket client, an event named `message` for an SSE
    /// client. Not recorded for replay.
    pub fn broadcastToChannel(self: *Hub, channel: []const u8, message: []const u8) void {
        self.mutex.lock(self.io) catch return;
        var snapshot: std.ArrayListUnmanaged(*ConnectionSlot) = .empty;
        defer snapshot.deinit(self.allocator);
        for (self.connections.items) |slot| {
            if (slot.inChannel(channel)) {
                self.snapshotAppend(&snapshot, slot);
            }
        }
        self.mutex.unlock(self.io);

        for (snapshot.items) |slot| {
            const failed = switch (slot.conn.type) {
                .ws => self.writeToSlot(slot, sendText, .{message}),
                .sse => self.writeToSlot(slot, sendSse, .{ "message", message }),
            };
            failed catch |err| {
                if (err != error.AlreadyClosed) self.drop(slot.conn.id);
            };
            self.releaseSlot(slot);
        }
    }

    // internal: writes one SSE event to a stream; callers go through `writeToConn`.
    pub fn sendSse(self: *Hub, stream: net.Stream, event: []const u8, data: []const u8) !void {
        var write_buf: [4096]u8 = undefined;
        var sw = net.Stream.Writer.init(stream, self.io, &write_buf);
        try writeSseFrame(&sw.interface, null, event, data);
        try sw.interface.flush();
    }
    // internal: `sendSse` with an `id:` line; used for channel events and replay.
    pub fn sendSseWithId(self: *Hub, stream: net.Stream, id: u64, event: []const u8, data: []const u8) !void {
        var write_buf: [4096]u8 = undefined;
        var sw = net.Stream.Writer.init(stream, self.io, &write_buf);
        try writeSseFrame(&sw.interface, id, event, data);
        try sw.interface.flush();
    }

    /// SSE comment line (leading ':') — spec-valid content the client's
    /// EventSource silently ignores as an event, but the bytes on the wire
    /// keep the TCP connection "hot" against idle-timeout proxies/LBs, and a
    /// write failure here is exactly as good a dead-connection signal as a
    /// real event would be.
    fn sendSseComment(self: *Hub, stream: net.Stream, comment: []const u8) !void {
        var write_buf: [128]u8 = undefined;
        var sw = net.Stream.Writer.init(stream, self.io, &write_buf);
        const writer = &sw.interface;
        try writer.writeAll(": ");
        try writer.writeAll(comment);
        try writer.writeAll("\n\n");
        try writer.flush();
    }

    // internal: one WebSocket text frame to `stream`; `Ws.send` calls it
    // through writeToConn, under the connection's lock.
    pub fn sendText(self: *Hub, stream: net.Stream, text: []const u8) !void {
        var write_buf: [4096]u8 = undefined;
        var sw = net.Stream.Writer.init(stream, self.io, &write_buf);
        const writer = &sw.interface;

        var header_buf: [10]u8 = undefined;
        var header_len: usize = 2;
        header_buf[0] = 0x81;

        if (text.len < 126) {
            header_buf[1] = @intCast(text.len);
        } else if (text.len < 65536) {
            header_buf[1] = 126;
            std.mem.writeInt(u16, header_buf[2..4], @intCast(text.len), .big);
            header_len = 4;
        } else {
            header_buf[1] = 127;
            std.mem.writeInt(u64, header_buf[2..10], text.len, .big);
            header_len = 10;
        }

        try writer.writeAll(header_buf[0..header_len]);
        try writer.writeAll(text);
        try writer.flush();
    }

    // Goes through remove() (global-lock find-and-unlink, then per-slot
    // io_mutex before the actual close) for each id, same as any other
    // caller — heartbeat/sweep discovering a dead connection isn't a
    // different case from a client disconnecting normally.
    fn pruneDead(self: *Hub, dead_ids: []const u64) void {
        for (dead_ids) |id| self.drop(id);
    }

    fn touchActivity(self: *Hub, touched_ids: []const u64, ts: std.Io.Timestamp) void {
        if (touched_ids.len == 0) return;
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        for (touched_ids) |id| {
            for (self.connections.items) |slot| {
                if (slot.conn.id == id) {
                    slot.conn.last_activity = ts;
                    break;
                }
            }
        }
    }

    fn now(self: *Hub) std.Io.Timestamp {
        return std.Io.Clock.awake.now(self.io);
    }

    // ─── Heartbeat ───────────────────────────────────────────────────
    // Periodic ": heartbeat\n\n" to every SSE connection, keeping the TCP
    // connection active against idle-timeout proxies/load balancers/mobile
    // carrier NATs — without it, a channel that goes quiet for a while can
    // get silently dropped mid-connection with neither side noticing until
    // the next real write fails. Opt-in (call startHeartbeat after init())
    // so existing callers/tests that never touch it are unaffected.

    // internal: `Server.sseHeartbeat` asks for it and listen() starts it.
    // Starts a thread that sends an SSE comment to every SSE connection every `interval_ms` (null: `default_heartbeat_ms`).
    pub fn startHeartbeat(self: *Hub, interval_ms: ?u64) !void {
        if (self.heartbeat_thread != null) return;
        self.heartbeat_running.store(true, .release);
        self.heartbeat_thread = try std.Thread.spawn(.{}, heartbeatLoop, .{ self, interval_ms orelse default_heartbeat_ms });
    }

    // internal: stops and joins the heartbeat thread; `deinit` calls it.
    pub fn stopHeartbeat(self: *Hub) void {
        if (self.heartbeat_thread) |t| {
            self.heartbeat_running.store(false, .release);
            t.join();
            self.heartbeat_thread = null;
        }
    }

    fn heartbeatLoop(self: *Hub, interval_ms: u64) void {
        while (self.heartbeat_running.load(.acquire)) {
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(@intCast(interval_ms)), .real) catch {};
            if (self.heartbeat_running.load(.acquire)) {
                self.sendHeartbeats();
            }
        }
    }

    // internal: one heartbeat round; public for the tests.
    // The actual per-tick heartbeat action, callable directly (deterministic,
    // no timer involved) — this is what startHeartbeat's background thread
    // calls on each tick, and what tests exercise instead of racing a timer.
    pub fn sendHeartbeats(self: *Hub) void {
        self.mutex.lock(self.io) catch return;
        var snapshot: std.ArrayListUnmanaged(*ConnectionSlot) = .empty;
        defer snapshot.deinit(self.allocator);
        for (self.connections.items) |slot| {
            if (slot.conn.type == .sse) self.snapshotAppend(&snapshot, slot);
        }
        self.mutex.unlock(self.io);

        const ts = self.now();
        var dead: std.ArrayListUnmanaged(u64) = .empty;
        defer dead.deinit(self.allocator);
        var touched: std.ArrayListUnmanaged(u64) = .empty;
        defer touched.deinit(self.allocator);

        for (snapshot.items) |slot| {
            defer self.releaseSlot(slot);
            self.writeToSlot(slot, sendSseComment, .{"heartbeat"}) catch |err| {
                if (err == error.AlreadyClosed) continue;
                dead.append(self.allocator, slot.conn.id) catch {};
                continue;
            };
            touched.append(self.allocator, slot.conn.id) catch {};
        }

        self.pruneDead(dead.items);
        self.touchActivity(touched.items, ts);
    }

    // ─── Proactive dead-connection sweep ────────────────────────────────
    // Heartbeat/emit/broadcast only ever discover a dead connection
    // reactively, on the next write attempt — a channel nobody emits to and
    // that never gets a heartbeat can accumulate zombie connections
    // indefinitely. Sweep independently probes any SSE connection that's
    // been idle for at least the sweep interval and removes ones that fail.

    // internal: `Server.sseSweep` asks for it and listen() starts it.
    // Starts a thread that probes idle SSE connections every `interval_ms` (null: `default_sweep_ms`).
    pub fn startSweep(self: *Hub, interval_ms: ?u64) !void {
        if (self.sweep_thread != null) return;
        self.sweep_running.store(true, .release);
        self.sweep_thread = try std.Thread.spawn(.{}, sweepLoop, .{ self, interval_ms orelse default_sweep_ms });
    }

    // internal: stops and joins the sweep thread; `deinit` calls it.
    pub fn stopSweep(self: *Hub) void {
        if (self.sweep_thread) |t| {
            self.sweep_running.store(false, .release);
            t.join();
            self.sweep_thread = null;
        }
    }

    fn sweepLoop(self: *Hub, interval_ms: u64) void {
        while (self.sweep_running.load(.acquire)) {
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(@intCast(interval_ms)), .real) catch {};
            if (self.sweep_running.load(.acquire)) {
                self.sweepDeadConnections(interval_ms);
            }
        }
    }

    // internal: one sweep round; public for the tests.
    // Directly callable (deterministic, no timer) — probes any SSE
    // connection idle for at least `idle_threshold_ms` and removes the ones
    // that fail to receive it.
    pub fn sweepDeadConnections(self: *Hub, idle_threshold_ms: u64) void {
        const ts = self.now();
        self.mutex.lock(self.io) catch return;
        var snapshot: std.ArrayListUnmanaged(*ConnectionSlot) = .empty;
        defer snapshot.deinit(self.allocator);
        for (self.connections.items) |slot| {
            // No last_activity yet (never touched since add()) counts as
            // idle — always eligible for the first sweep pass.
            const idle_ms = if (slot.conn.last_activity) |la| la.durationTo(ts).toMilliseconds() else std.math.maxInt(i64);
            if (slot.conn.type == .sse and idle_ms >= @as(i64, @intCast(idle_threshold_ms))) {
                self.snapshotAppend(&snapshot, slot);
            }
        }
        self.mutex.unlock(self.io);

        var dead: std.ArrayListUnmanaged(u64) = .empty;
        defer dead.deinit(self.allocator);
        var touched: std.ArrayListUnmanaged(u64) = .empty;
        defer touched.deinit(self.allocator);

        for (snapshot.items) |slot| {
            defer self.releaseSlot(slot);
            self.writeToSlot(slot, sendSseComment, .{"ping"}) catch |err| {
                if (err == error.AlreadyClosed) continue;
                dead.append(self.allocator, slot.conn.id) catch {};
                continue;
            };
            touched.append(self.allocator, slot.conn.id) catch {};
        }

        self.pruneDead(dead.items);
        self.touchActivity(touched.items, ts);
    }
};

fn makeSocketPair() ![2]net.Socket {
    var fds: [2]posix.fd_t = undefined;
    const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
    if (rc != 0) return error.Unexpected;
    return .{
        net.Socket{ .handle = fds[0], .address = .{ .ip4 = .{ .bytes = [4]u8{ 0, 0, 0, 0 }, .port = 0 } } },
        net.Socket{ .handle = fds[1], .address = .{ .ip4 = .{ .bytes = [4]u8{ 0, 0, 0, 0 }, .port = 0 } } },
    };
}

const testing = std.testing;

test "Hub: init and deinit" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try testing.expectEqual(@as(usize, 0), hub.count());
}

test "Hub: add increases count" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // sockets[0] is handed to the Hub below and stays registered for the
    // whole test — Hub.deinit() closes every registered connection's stream,
    // so a separate `defer sockets[0].close(io)` here would double-close it
    // (crashes as EBADF/use-after-free in debug builds). Only sockets[1] —
    // never owned by the Hub — needs its own defer.
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] } });
    try testing.expectEqual(@as(usize, 1), hub.count());
}

test "Hub: remove decreases count" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 99, .stream = .{ .socket = sockets[0] } });
    hub.remove(99);
    try testing.expectEqual(@as(usize, 0), hub.count());
}

test "Hub: remove nonexistent id does not crash" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    hub.remove(404);
    try testing.expectEqual(@as(usize, 0), hub.count());
}

test "Hub: broadcast writes valid WS frame" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // sockets[0] stays registered in the Hub (write succeeds, never removed)
    // — see the comment in "Hub: add increases count" for why it must not
    // also be closed here.
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] } });

    const msg = "hello";
    hub.broadcast(msg);

    var buf: [64]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);
    try reader.interface.readSliceAll(buf[0..2]);
    try testing.expectEqual(@as(u8, 0x81), buf[0]);
    try testing.expectEqual(@as(u8, msg.len), buf[1]);
    try reader.interface.readSliceAll(buf[0..msg.len]);
    try testing.expectEqualStrings(msg, buf[0..msg.len]);
}

test "Hub: broadcast removes dead connection" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // remove() no longer closes the socket itself (that's handleConnection's
    // job in real usage — see remove()'s doc comment) — the test owns
    // closing sockets[0] here since nothing else will.
    defer sockets[0].close(io);
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] } });
    try testing.expectEqual(@as(usize, 1), hub.count());

    try (net.Stream{ .socket = sockets[0] }).shutdown(io, .send);
    hub.broadcast("anything");
    try testing.expectEqual(@as(usize, 0), hub.count());
}

test "Hub: broadcast delivers to all connections" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets_a = try makeSocketPair();
    const sockets_b = try makeSocketPair();
    // Both sockets_a[0] and sockets_b[0] are handed to the Hub below and stay
    // registered for the whole test (broadcast succeeds, nothing removed) —
    // see "Hub: add increases count" for why they must not also be closed here.
    defer sockets_a[1].close(io);
    defer sockets_b[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets_a[0] } });
    try hub.add(.{ .id = 2, .stream = .{ .socket = sockets_b[0] } });

    const msg = "ping";
    hub.broadcast(msg);

    var buf_a: [64]u8 = undefined;
    var read_buf_a: [256]u8 = undefined;
    var reader_a = net.Stream.Reader.init(.{ .socket = sockets_a[1] }, io, &read_buf_a);
    try reader_a.interface.readSliceAll(buf_a[0..2]);
    try testing.expectEqual(@as(u8, 0x81), buf_a[0]);
    try testing.expectEqual(@as(u8, msg.len), buf_a[1]);

    var buf_b: [64]u8 = undefined;
    var read_buf_b: [256]u8 = undefined;
    var reader_b = net.Stream.Reader.init(.{ .socket = sockets_b[1] }, io, &read_buf_b);
    try reader_b.interface.readSliceAll(buf_b[0..2]);
    try testing.expectEqual(@as(u8, 0x81), buf_b[0]);
    try testing.expectEqual(@as(u8, msg.len), buf_b[1]);
}

test "Hub: add duplicate id returns error" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets_a = try makeSocketPair();
    const sockets_b = try makeSocketPair();
    // sockets_a[0] is handed to the Hub and stays registered — see "Hub: add
    // increases count". sockets_b[0] is REJECTED (duplicate id), so it's
    // never Hub-owned and keeps its own defer close.
    defer sockets_a[1].close(io);
    defer sockets_b[0].close(io);
    defer sockets_b[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    try hub.add(.{ .id = 7, .stream = .{ .socket = sockets_a[0] } });
    try testing.expectError(
        error.DuplicateId,
        hub.add(.{ .id = 7, .stream = .{ .socket = sockets_b[0] } }),
    );
    try testing.expectEqual(@as(usize, 1), hub.count());
}

test "Hub: broadcastToChannel delivers only to matching channel" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets_a = try makeSocketPair();
    const sockets_b = try makeSocketPair();
    // Both sockets_a[0] (targeted, write succeeds) and sockets_b[0] (never
    // targeted, no removal ever triggered for it) stay registered through
    // the whole test — see "Hub: add increases count".
    defer sockets_a[1].close(io);
    defer sockets_b[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets_a[0] }, .channel = "room:1" });
    try hub.add(.{ .id = 2, .stream = .{ .socket = sockets_b[0] }, .channel = "room:2" });

    hub.broadcastToChannel("room:1", "hello");

    var buf: [64]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets_a[1] }, io, &read_buf);
    try reader.interface.readSliceAll(buf[0..2]);
    try testing.expectEqual(@as(u8, 0x81), buf[0]);

    try (net.Stream{ .socket = sockets_b[0] }).shutdown(io, .send);
}

test "Hub: broadcast still delivers to all regardless of channel" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets_a = try makeSocketPair();
    const sockets_b = try makeSocketPair();
    // Both sockets_a[0] and sockets_b[0] stay registered through the whole
    // test (broadcast succeeds to both) — see "Hub: add increases count".
    defer sockets_a[1].close(io);
    defer sockets_b[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets_a[0] }, .channel = "room:1" });
    try hub.add(.{ .id = 2, .stream = .{ .socket = sockets_b[0] }, .channel = "room:2" });

    hub.broadcast("global");

    var buf_a: [64]u8 = undefined;
    var read_buf_a: [256]u8 = undefined;
    var reader_a = net.Stream.Reader.init(.{ .socket = sockets_a[1] }, io, &read_buf_a);
    try reader_a.interface.readSliceAll(buf_a[0..2]);
    try testing.expectEqual(@as(u8, 0x81), buf_a[0]);

    var buf_b: [64]u8 = undefined;
    var read_buf_b: [256]u8 = undefined;
    var reader_b = net.Stream.Reader.init(.{ .socket = sockets_b[1] }, io, &read_buf_b);
    try reader_b.interface.readSliceAll(buf_b[0..2]);
    try testing.expectEqual(@as(u8, 0x81), buf_b[0]);
}

test "Hub: emit serializes JSON with event and data" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // sockets[0] stays registered in the Hub — see "Hub: add increases count".
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    // emit()/broadcastEvent() only sends to .sse-typed connections — without
    // this, the read below blocks forever waiting for data that never comes.
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .type = .sse });

    hub.emit("alert", .{ .message = "test", .count = @as(i32, 42) });

    // SSE wire format is plain text ("event: X\ndata: Y\n\n"), not a
    // length-prefixed WS binary frame — read the exact expected message.
    const expected = "event: alert\ndata: {\"message\":\"test\",\"count\":42}\n\n";
    var buf: [expected.len]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualStrings(expected, &buf);

    const data_start = std.mem.indexOf(u8, &buf, "data: ").? + "data: ".len;
    const payload = buf[data_start .. buf.len - 2]; // trim trailing "\n\n"
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const data_obj = parsed.value.object;
    try testing.expectEqualStrings("test", data_obj.get("message").?.string);
    try testing.expectEqual(@as(i64, 42), data_obj.get("count").?.integer);
}

test "Hub: emitTo delivers only to matching channel" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets_a = try makeSocketPair();
    const sockets_b = try makeSocketPair();
    // Both sockets_a[0] (targeted) and sockets_b[0] (never targeted, never
    // removed) stay registered through the whole test — see "Hub: add
    // increases count".
    defer sockets_a[1].close(io);
    defer sockets_b[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    // emitTo()/broadcastToChannelEvent() only sends to .sse-typed connections.
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets_a[0] }, .channel = "room:1", .type = .sse });
    try hub.add(.{ .id = 2, .stream = .{ .socket = sockets_b[0] }, .channel = "room:2", .type = .sse });

    hub.emitTo("room:1", "notice", .{ .text = "only room:1" });

    // SSE wire format is plain text, not a length-prefixed WS binary frame.
    const expected = "id: 1\nevent: notice\ndata: {\"text\":\"only room:1\"}\n\n";
    var buf: [expected.len]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets_a[1] }, io, &read_buf);
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualStrings(expected, &buf);

    // sockets_b should NOT receive anything — shutdown its send side to confirm
    try (net.Stream{ .socket = sockets_b[0] }).shutdown(io, .send);
}

test "Hub: notifyUser delivers to user:42 channel" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // sockets[0] stays registered in the Hub — see "Hub: add increases count".
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    // notifyUser()/emitTo() only sends to .sse-typed connections — without
    // this, the read below blocks forever waiting for data that never comes.
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .channel = "user:42", .type = .sse });

    hub.notifyUser(42, "private", .{ .msg = "secret" });

    // SSE wire format is plain text, not a length-prefixed WS binary frame.
    const expected = "id: 1\nevent: private\ndata: {\"msg\":\"secret\"}\n\n";
    var buf: [expected.len]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualStrings(expected, &buf);
}

test "Hub: broadcastToChannel removes dead connection" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // remove() doesn't close the socket itself (see its doc comment) —
    // the test owns closing sockets[0] here since nothing else will.
    defer sockets[0].close(io);
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .channel = "room:1" });
    try testing.expectEqual(@as(usize, 1), hub.count());

    try (net.Stream{ .socket = sockets[0] }).shutdown(io, .send);
    hub.broadcastToChannel("room:1", "msg");
    try testing.expectEqual(@as(usize, 0), hub.count());
}

test "Hub: emitTo removes dead connection on write failure" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // remove() doesn't close the socket itself (see its doc comment) —
    // the test owns closing sockets[0] here since nothing else will.
    defer sockets[0].close(io);
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .channel = "room:1", .type = .sse });
    try testing.expectEqual(@as(usize, 1), hub.count());

    try (net.Stream{ .socket = sockets[0] }).shutdown(io, .send);
    hub.emitTo("room:1", "notice", .{ .text = "hi" });
    try testing.expectEqual(@as(usize, 0), hub.count());
}

test "Hub: emit (global) removes dead connection on write failure" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // remove() doesn't close the socket itself (see its doc comment) —
    // the test owns closing sockets[0] here since nothing else will.
    defer sockets[0].close(io);
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .type = .sse });
    try testing.expectEqual(@as(usize, 1), hub.count());

    try (net.Stream{ .socket = sockets[0] }).shutdown(io, .send);
    hub.emit("alert", .{ .msg = "hi" });
    try testing.expectEqual(@as(usize, 0), hub.count());
}

test "Hub: emit (global) reaches sse connections regardless of channel" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // sockets[0] stays registered in the Hub — see "Hub: add increases count".
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    // channel is set but irrelevant to emit() — it's a global broadcast, not
    // scoped like emitTo(). Only conn.type == .sse is checked (broadcastEvent).
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .channel = "room:whatever", .type = .sse });

    hub.emit("alert", .{ .msg = "hi" });

    var buf: [7]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualStrings("event: ", &buf);
}

// ── Heartbeat ───────────────────────────────────────────────────────────
// Tests call sendHeartbeats()/sweepDeadConnections() directly rather than
// going through startHeartbeat()/startSweep() — deterministic, no racing a
// background thread against a fixed test timeout.

test "Hub: sendHeartbeats writes an SSE comment to sse connections" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .type = .sse });

    hub.sendHeartbeats();

    const expected = ": heartbeat\n\n";
    var buf: [expected.len]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualStrings(expected, &buf);
}

test "Hub: sendHeartbeats does not write to ws connections" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .type = .ws });

    hub.sendHeartbeats();

    // Nothing should arrive — shutdown the send side to confirm, matching
    // the pattern used by "delivers only to matching channel" tests above.
    try (net.Stream{ .socket = sockets[0] }).shutdown(io, .send);
}

test "Hub: sendHeartbeats removes a dead sse connection" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // remove() doesn't close the socket itself (see its doc comment) —
    // the test owns closing sockets[0] here since nothing else will (it's
    // no longer registered by the time hub.deinit() runs).
    defer sockets[0].close(io);
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .type = .sse });
    try testing.expectEqual(@as(usize, 1), hub.count());

    try (net.Stream{ .socket = sockets[0] }).shutdown(io, .send);
    hub.sendHeartbeats();
    try testing.expectEqual(@as(usize, 0), hub.count());
}

// ── Proactive sweep ─────────────────────────────────────────────────────

test "Hub: sweepDeadConnections pings a never-active sse connection" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .type = .sse });

    // idle_threshold_ms=0 — every connection (just added, last_activity set
    // by add()) already qualifies as "idle for at least 0ms".
    hub.sweepDeadConnections(0);

    const expected = ": ping\n\n";
    var buf: [expected.len]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);
    try reader.interface.readSliceAll(&buf);
    try testing.expectEqualStrings(expected, &buf);
}

test "Hub: sweepDeadConnections skips a connection under the idle threshold" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // sockets[0] stays registered in the Hub — see "Hub: add increases count".
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .type = .sse });

    // Just added (last_activity ~= now) — an hour-long idle threshold means
    // this connection is nowhere close to eligible, so nothing gets sent.
    hub.sweepDeadConnections(60 * 60 * 1000);

    // Confirm nothing arrived without blocking forever waiting for it.
    try (net.Stream{ .socket = sockets[0] }).shutdown(io, .send);
}

test "Hub: sweepDeadConnections removes a dead sse connection" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    // remove() doesn't close the socket itself (see its doc comment) —
    // the test owns closing sockets[0] here since nothing else will (it's
    // no longer registered by the time hub.deinit() runs).
    defer sockets[0].close(io);
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .type = .sse });
    try testing.expectEqual(@as(usize, 1), hub.count());

    try (net.Stream{ .socket = sockets[0] }).shutdown(io, .send);
    hub.sweepDeadConnections(0);
    try testing.expectEqual(@as(usize, 0), hub.count());
}

// ── Replay buffer (Last-Event-ID) ───────────────────────────────────────

test "Hub: historySince returns only entries after last_id, in order" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    // No connections needed — emitTo() records history even with nobody
    // subscribed yet (json alloc/free still happens, just nothing to send to).
    hub.emitTo("room:1", "a", .{ .n = 1 });
    hub.emitTo("room:1", "b", .{ .n = 2 });
    hub.emitTo("room:1", "c", .{ .n = 3 });

    const entries = try hub.historySince(testing.allocator, "room:1", 1);
    defer {
        for (entries) |e| {
            testing.allocator.free(e.event);
            testing.allocator.free(e.data);
        }
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(@as(u64, 2), entries[0].id);
    try testing.expectEqualStrings("b", entries[0].event);
    try testing.expectEqual(@as(u64, 3), entries[1].id);
    try testing.expectEqualStrings("c", entries[1].event);
}

test "Hub: historySince with last_id caught up to the newest entry returns empty" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    hub.emitTo("room:1", "a", .{});

    const entries = try hub.historySince(testing.allocator, "room:1", 1);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "Hub: historySince on a channel with no history returns empty" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    const entries = try hub.historySince(testing.allocator, "never:emitted", 0);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "Hub: recordHistory prunes past history_max_entries" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    var i: usize = 0;
    while (i < 55) : (i += 1) {
        hub.emitTo("room:prune", "e", .{ .n = i });
    }

    const entries = try hub.historySince(testing.allocator, "room:prune", 0);
    defer {
        for (entries) |e| {
            testing.allocator.free(e.event);
            testing.allocator.free(e.data);
        }
        testing.allocator.free(entries);
    }
    // 55 emitted, cap is 50 — oldest 5 (ids 1..5) pruned, newest 50 remain.
    try testing.expectEqual(@as(usize, 50), entries.len);
    try testing.expectEqual(@as(u64, 6), entries[0].id);
    try testing.expectEqual(@as(u64, 55), entries[entries.len - 1].id);
}

// ── Multiple channels per connection ────────────────────────────────────

fn readExact(io: std.Io, sock: net.Socket, comptime n: usize) ![n]u8 {
    var buf: [n]u8 = undefined;
    var read_buf: [512]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sock }, io, &read_buf);
    try reader.interface.readSliceAll(&buf);
    return buf;
}

test "Hub: addChannel makes one connection receive emitTo on every subscribed channel" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .channel = "condo:1", .type = .sse });
    try hub.addChannel(1, "user:9");

    hub.emitTo("condo:1", "a", .{ .k = 1 });
    hub.emitTo("user:9", "b", .{ .k = 1 });
    hub.emitTo("other", "c", .{ .k = 1 });

    const expected = "id: 1\nevent: a\ndata: {\"k\":1}\n\nid: 2\nevent: b\ndata: {\"k\":1}\n\n";
    const got = try readExact(io, sockets[1], expected.len);
    try testing.expectEqualStrings(expected, &got);
}

test "Hub: addChannel is idempotent and channelCount counts each connection once" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const s1 = try makeSocketPair();
    defer s1[1].close(io);
    const s2 = try makeSocketPair();
    defer s2[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    try hub.add(.{ .id = 1, .stream = .{ .socket = s1[0] }, .channel = "a", .type = .sse });
    try hub.add(.{ .id = 2, .stream = .{ .socket = s2[0] }, .type = .sse });
    try hub.addChannel(1, "b");
    try hub.addChannel(1, "b");
    try hub.addChannel(1, "a");
    try hub.addChannel(2, "b");

    try testing.expectEqual(@as(usize, 1), hub.channelCount("a"));
    try testing.expectEqual(@as(usize, 2), hub.channelCount("b"));
    try testing.expectEqual(@as(usize, 0), hub.channelCount("c"));
    try testing.expectError(error.UnknownConnection, hub.addChannel(99, "x"));
}

test "Hub: updateChannel (join) drops the extra subscriptions" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .channel = "a", .type = .sse });
    try hub.addChannel(1, "b");
    try hub.updateChannel(1, "c");
    try testing.expectEqual(@as(usize, 0), hub.channelCount("a"));
    try testing.expectEqual(@as(usize, 0), hub.channelCount("b"));
    try testing.expectEqual(@as(usize, 1), hub.channelCount("c"));
}

test "Hub: remove frees extra subscriptions (no leak)" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[0].close(io);
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .type = .sse });
    try hub.addChannel(1, "x");
    try hub.addChannel(1, "y");
    hub.remove(1);
    try testing.expectEqual(@as(usize, 0), hub.channelCount("x"));
}

test "Hub: event ids are hub-wide, increasing across channels" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    hub.emitTo("a", "e1", .{ .k = 1 });
    hub.emitTo("b", "e2", .{ .k = 1 });
    hub.emitTo("a", "e3", .{ .k = 1 });

    const a = try hub.historySince(testing.allocator, "a", 0);
    defer {
        for (a) |e| {
            testing.allocator.free(e.event);
            testing.allocator.free(e.data);
        }
        testing.allocator.free(a);
    }
    const b = try hub.historySince(testing.allocator, "b", 0);
    defer {
        for (b) |e| {
            testing.allocator.free(e.event);
            testing.allocator.free(e.data);
        }
        testing.allocator.free(b);
    }
    try testing.expectEqual(@as(u64, 1), a[0].id);
    try testing.expectEqual(@as(u64, 3), a[1].id);
    try testing.expectEqual(@as(u64, 2), b[0].id);
}

test "Hub: writeToConn on an unknown connection is an error, not a write" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try testing.expectError(error.UnknownConnection, hub.writeToConn(42, Hub.sendSse, .{ "x", "{}" }));
}

test "writeSseFrame: every data line gets its own data: prefix (multi-line HTML survives)" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeSseFrame(&w, 7, "row", "<tr>\n  <td>a</td>\r\n</tr>");
    try testing.expectEqualStrings("id: 7\nevent: row\ndata: <tr>\ndata:   <td>a</td>\ndata: </tr>\n\n", w.buffered());
    var w2: std.Io.Writer = .fixed(&buf);
    try writeSseFrame(&w2, null, "message", "{\"a\":1}");
    try testing.expectEqualStrings("event: message\ndata: {\"a\":1}\n\n", w2.buffered());
}

test "Hub: emitHtmlTo records the raw HTML (not JSON) for replay" {
    var threaded = std.Io.Threaded.init_single_threaded;
    var hub = Hub.init(testing.allocator, threaded.io());
    defer hub.deinit();
    hub.emitHtmlTo("org:1", "badge", "<span>3</span>\n");
    const entries = try hub.historySince(testing.allocator, "org:1", 0);
    defer {
        for (entries) |e| {
            testing.allocator.free(e.event);
            testing.allocator.free(e.data);
        }
        testing.allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("<span>3</span>\n", entries[0].data);
    try testing.expectEqualStrings("badge", entries[0].event);
}

// internal: the SSE wire format, shared by the senders of this file.
// One SSE frame: optional `id:`, `event:`, then `data:` once per line of
// `data` (CR/LF or LF), and the blank line that ends the event. A single
// `data:` with raw newlines inside would end the event early.
pub fn writeSseFrame(w: *std.Io.Writer, id: ?u64, event: []const u8, data: []const u8) !void {
    if (id) |n| try w.print("id: {d}\n", .{n});
    try w.writeAll("event: ");
    try w.writeAll(event);
    try w.writeAll("\n");
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        try w.writeAll("data: ");
        try w.writeAll(std.mem.trimEnd(u8, line, "\r"));
        try w.writeAll("\n");
    }
    try w.writeAll("\n");
}
