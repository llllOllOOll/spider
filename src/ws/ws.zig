//! `spider.Ws`: one WebSocket connection, as the handler of a WebSocket route
//! (`Server.ws`) receives it, and the `Message` it reads.

const std = @import("std");
const Ctx = @import("../core/context.zig").Ctx;
const Response = @import("../core/context.zig").Response;
const websocket = @import("websocket.zig");
const Hub = @import("hub.zig").Hub;

/// One message received from the client, as `Ws.next` returns it.
pub const Message = struct {
    /// The payload, allocated in the connection's arena.
    data: []const u8,
    /// Whether the client sent a text or a binary frame.
    type: enum { text, binary },
};

/// One open WebSocket connection. The handler of a `Server.ws` route receives
/// it after the handshake and reads messages until the client leaves; when
/// the handler returns, the connection is closed.
///
/// ```zig
/// fn chat(ws: *spider.Ws) !void {
///     while (try ws.next()) |message| {
///         ws.broadcast(message.data);
///     }
/// }
/// ```
///
/// Each WebSocket route has a hub of its own: `broadcast` and `broadcastTo`
/// reach the connections of the same route, the sender included.
pub const Ws = struct {
    _server: websocket.Server,
    _hub: *Hub,
    _conn_id: u64,
    /// The channel given to `join`. Empty before that.
    channel: []const u8 = "",
    /// The request's params at the time of the handshake: route segments and
    /// what the middlewares set. See `param`.
    params: std.StringHashMapUnmanaged([]const u8) = .{},
    /// Lives as long as the connection; received messages are allocated here.
    arena: std.mem.Allocator,
    /// The server's Io.
    io: std.Io,

    /// Waits for the next text or binary message. Null when the connection is
    /// over: the client closed it, a read failed, or a frame was not accepted (a
    /// payload over 16 MiB, a continuation frame). Pings are answered and
    /// skipped. The payload is allocated in `arena` and is not freed before the
    /// connection ends.
    pub fn next(self: *Ws) !?Message {
        const frame = self._server.readFrame(self.arena) catch {
            return null;
        };
        const f = frame orelse {
            return null;
        };
        return switch (f.opcode) {
            .text => Message{ .data = f.payload, .type = .text },
            .binary => Message{ .data = f.payload, .type = .binary },
            .ping, .pong => self.next(),
            .close => null,
            .continuation => null,
        };
    }

    /// `join` on the channel `user:<user_id>`.
    pub fn joinUser(self: *Ws, user_id: u64) !void {
        // join() keeps the slice for as long as the connection lives (here
        // and in the hub): it has to outlive this call. Same as Sse.joinUser.
        const channel = try std.fmt.allocPrint(self.arena, "user:{d}", .{user_id});
        try self.join(channel);
    }

    /// Puts this connection on `channel`, leaving the one it was on:
    /// `broadcastTo(channel, ...)` then reaches it. `channel` is not copied: it
    /// must stay valid while the connection is open.
    pub fn join(self: *Ws, channel: []const u8) !void {
        self.channel = channel;
        try self._hub.updateChannel(self._conn_id, channel);
    }

    /// Sends a text message to this connection only.
    pub fn send(self: *Ws, text: []const u8) !void {
        // Under the hub's lock for this connection: a broadcast from
        // another connection writes to the same socket, and two writers
        // at once mix the bytes of their frames.
        self._hub.writeToConn(self._conn_id, Hub.sendText, .{text}) catch |err| switch (err) {
            error.UnknownConnection => return self._server.sendText(text),
            else => return err,
        };
    }

    /// Sends a text message to every connection of this route, this one
    /// included, whatever their channel. A connection whose write fails is
    /// dropped.
    pub fn broadcast(self: *Ws, text: []const u8) void {
        self._hub.broadcast(text);
    }

    /// `broadcast` with a formatted message.
    pub fn broadcastFmt(self: *Ws, comptime fmt: []const u8, args: anytype) void {
        self._hub.broadcastFmt(fmt, args);
    }

    /// Sends a text message to the connections of this route that joined
    /// `channel`.
    pub fn broadcastTo(self: *Ws, channel: []const u8, text: []const u8) void {
        self._hub.broadcastToChannel(channel, text);
    }

    /// `broadcastTo` with a formatted message.
    pub fn broadcastToFmt(self: *Ws, channel: []const u8, comptime fmt: []const u8, args: anytype) void {
        self._hub.broadcastToChannelFmt(channel, fmt, args);
    }

    /// A request param by name: a route segment or a value a middleware set. Null when there is none.
    pub fn param(self: *Ws, key: []const u8) ?[]const u8 {
        return self.params.get(key);
    }
};
