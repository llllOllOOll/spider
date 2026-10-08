//! Browser reload for `spider dev`.
//!
//! When the app runs under `spider dev` (SPIDER_DEV is set) and was built in
//! Debug, the server:
//!
//!   * adds `<script src="/_spider/dev.js">` before `</body>` of every HTML
//!     page it sends;
//!   * serves that script and a WebSocket at `/_spider/dev`, before routing
//!     and before any middleware (an app's auth never sees them).
//!
//! The socket sends one message, an id made when the process started, and
//! then stays open. `spider dev` replaces the process after a build: the
//! socket drops, the script reconnects until the new process is listening,
//! receives a different id, and reloads the page. A dropped connection to
//! the same process (same id) reloads nothing.
//!
//! Same origin as the app on purpose: a dev server on another port is
//! blocked by an app whose Content-Security-Policy has `script-src 'self'`
//! or `connect-src 'self'`.
//!
//! None of this exists in a release build (`compiled_in`), whatever the
//! environment says.

const std = @import("std");
const builtin = @import("builtin");
const env = @import("../internal/env.zig");
const ws = @import("../ws/websocket.zig");

pub const compiled_in = builtin.mode == .debug;

/// Set by `spider dev` for the app it starts.
pub const env_name = "SPIDER_DEV";
pub const script_path = "/_spider/dev.js";
pub const socket_path = "/_spider/dev";
pub const script_tag = "<script src=\"" ++ script_path ++ "\" defer></script>";

pub const script =
    \\(function () {
    \\  if (window.__spiderDev) return;
    \\  window.__spiderDev = true;
    \\  // wss:// on an https page (ws:// there is blocked as mixed content).
    \\  var url = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/_spider/dev';
    \\  var boot = null;
    \\  var leaving = false;
    \\  window.addEventListener('beforeunload', function () { leaving = true; });
    \\  function connect() {
    \\    var sock = new WebSocket(url);
    \\    sock.onmessage = function (e) {
    \\      if (boot === null) { boot = e.data; return; }
    \\      if (e.data !== boot && !leaving) { leaving = true; location.reload(); }
    \\    };
    \\    sock.onclose = function () { if (!leaving) setTimeout(connect, 150); };
    \\  }
    \\  connect();
    \\})();
    \\
;

/// `Config.dev_reload` as a decision: an explicit value wins, otherwise the
/// environment. Always false in a release build.
pub fn resolve(configured: ?bool) bool {
    if (!compiled_in) return false;
    return configured orelse (env.get(env_name) != null);
}

var boot_id: [16]u8 = @splat('0');
var boot_id_made: std.atomic.Value(bool) = .init(false);

/// The id of this process, made on the first call.
pub fn bootId(io: std.Io) []const u8 {
    if (!boot_id_made.load(.acquire)) {
        var bytes: [8]u8 = undefined;
        io.random(&bytes);
        const hex = std.fmt.bytesToHex(bytes, .lower);
        // Two first callers write the same kind of value; either is fine as
        // long as it no longer changes afterwards.
        if (!boot_id_made.swap(true, .acq_rel)) boot_id = hex;
    }
    return &boot_id;
}

/// `html` with the script tag before its last `</body>`. A fragment (no
/// `</body>`), or a page that already has the tag, comes back as it is.
pub fn inject(arena: std.mem.Allocator, html: []const u8) []const u8 {
    const at = std.mem.lastIndexOf(u8, html, "</body>") orelse return html;
    if (std.mem.indexOf(u8, html, script_path) != null) return html;
    return std.mem.concat(arena, u8, &.{ html[0..at], script_tag, html[at..] }) catch html;
}

pub fn isHtml(content_type: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(content_type, "text/html");
}

/// The WebSocket: sends the boot id and holds the connection until the
/// client closes it or this process ends. Returns false when the request
/// was not a WebSocket upgrade (nothing was written).
pub fn serveSocket(
    io: std.Io,
    stream: std.Io.net.Stream,
    arena: std.mem.Allocator,
    headers: *const std.StringHashMapUnmanaged([]const u8),
) bool {
    var server = ws.Server.init(stream, io, arena);
    const upgraded = server.handshake(arena, headers) catch return true;
    if (!upgraded) return false;
    server.sendText(bootId(io)) catch return true;
    while (true) {
        const frame = server.readFrame(arena) catch break orelse break;
        if (frame.opcode == .close) break;
    }
    return true;
}

test "inject: before the last </body>, once, and never into a fragment" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "<html><body><p>x</p>" ++ script_tag ++ "</body></html>",
        inject(arena, "<html><body><p>x</p></body></html>"),
    );
    // A page that quotes "</body>" in its text: the real one is the last.
    try std.testing.expectEqualStrings(
        "<body><pre>&lt;/body&gt; </body> text</pre>" ++ script_tag ++ "</body>",
        inject(arena, "<body><pre>&lt;/body&gt; </body> text</pre></body>"),
    );
    const fragment = "<div id=\"list\"><p>row</p></div>";
    try std.testing.expectEqualStrings(fragment, inject(arena, fragment));
    const once = inject(arena, "<body></body>");
    try std.testing.expectEqualStrings(once, inject(arena, once));
}

test "script: same origin, wss on https, reloads only on a different boot id" {
    try std.testing.expect(std.mem.indexOf(u8, script, "location.host + '" ++ socket_path ++ "'") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "'wss://' : 'ws://'") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "e.data !== boot") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "http://") == null);
}

test "resolve: an explicit value wins; off in a release build" {
    if (!compiled_in) {
        try std.testing.expect(!resolve(true));
        return;
    }
    try std.testing.expect(resolve(true));
    try std.testing.expect(!resolve(false));
}

test "bootId: 16 hex characters, the same on every call" {
    const a = bootId(std.testing.io);
    try std.testing.expectEqual(@as(usize, 16), a.len);
    for (a) |ch| try std.testing.expect(std.ascii.isHex(ch));
    try std.testing.expectEqualStrings(a, bootId(std.testing.io));
}
