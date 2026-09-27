//! DISABLED — not registered by the server (see core/app.zig). A WebSocket
//! at /_spider/reload plus a script that reloads the page when the server
//! comes back after a restart. Kept for a future `spider dev` (watch files,
//! rebuild, reload); nothing uses it today.
const std = @import("std");
const Ctx = @import("../core/context.zig").Ctx;
const Response = @import("../core/context.zig").Response;
const ws = @import("../ws/websocket.zig");

pub const SCRIPT =
    \\<script>
    \\(function() {
    \\  if (window.__spiderReload) return;
    \\  window.__spiderReload = true;
    \\  // wss:// on an https page (a ws:// socket there is blocked as mixed
    \\  // content); location.host carries the port when there is one.
    \\  var url = (window.location.protocol === 'https:' ? 'wss://' : 'ws://') + window.location.host + '/_spider/reload';
    \\  function connect() {
    \\    var sock = new WebSocket(url);
    \\    sock.onopen = function() {
    \\      console.log('[Spider] live reload ready');
    \\    };
    \\    sock.onclose = function() {
    \\      console.log('[Spider] server restarting...');
    \\      setTimeout(tryReconnect, 500);
    \\    };
    \\  }
    \\  function tryReconnect() {
    \\    var test = new WebSocket(url);
    \\    test.onopen = function() {
    \\      console.log('[Spider] reloading...');
    \\      window.location.reload();
    \\    };
    \\    test.onerror = function() {
    \\      setTimeout(tryReconnect, 500);
    \\    };
    \\  }
    \\  connect();
    \\})();
    \\</script>
;

pub fn handler(c: *Ctx) !Response {
    var server = ws.Server.init(c._stream, c._io, c.arena);
    const upgraded = try server.handshake(c.arena, &c._headers);
    if (!upgraded) return c.text("", .{});

    while (true) {
        const frame = server.readFrame(c.arena) catch break orelse break;
        switch (frame.opcode) {
            .close => break,
            else => {},
        }
    }

    return c.text("", .{});
}

test "SCRIPT: follows the page's scheme and host (wss on https, no hardcoded port)" {
    try std.testing.expect(std.mem.indexOf(u8, SCRIPT, "'wss://' : 'ws://'") != null);
    try std.testing.expect(std.mem.indexOf(u8, SCRIPT, "window.location.host +") != null);
    try std.testing.expect(std.mem.indexOf(u8, SCRIPT, "'80'") == null);
}
