const std = @import("std");
const Ctx = @import("../core/context.zig").Ctx;
const Response = @import("../core/context.zig").Response;
const ws = @import("../ws/websocket.zig");

pub const SCRIPT =
    \\<script>
    \\(function() {
    \\  if (window.__spiderReload) return;
    \\  window.__spiderReload = true;
    \\  var port = window.location.port || '80';
    \\  var host = window.location.hostname;
    \\  function connect() {
    \\    var sock = new WebSocket('ws://' + host + ':' + port + '/_spider/reload');
    \\    sock.onopen = function() {
    \\      console.log('[Spider] live reload ready');
    \\    };
    \\    sock.onclose = function() {
    \\      console.log('[Spider] server restarting...');
    \\      setTimeout(tryReconnect, 500);
    \\    };
    \\  }
    \\  function tryReconnect() {
    \\    var test = new WebSocket('ws://' + host + ':' + port + '/_spider/reload');
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
