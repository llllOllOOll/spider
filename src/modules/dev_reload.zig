//! Browser reload for `spider dev`.
//!
//! When the app runs under `spider dev` (SPIDER_DEV is set) and was built in
//! Debug, the server:
//!
//!   * adds `<script src="/_spider/dev.js">` before `</body>` of every HTML
//!     page it sends (spider.gzip adds it itself, before compressing; a page
//!     compressed by an app's own middleware cannot get it);
//!   * serves that script and a WebSocket at `/_spider/dev`, before routing
//!     and before any middleware (an app's auth never sees them).
//!
//! The socket first sends `id:<boot id>`, made when the process started.
//! `spider dev` replaces the process after a build: the socket drops, the
//! script reconnects until the new process is listening, receives a
//! different id, and reloads the page. A dropped connection to the same
//! process (same id) reloads nothing.
//!
//! When a build changed only what the page loads besides the binary (the
//! stylesheet), the process is not replaced. `spider dev` then rewrites the
//! file it named in SPIDER_DEV; the socket notices and sends `reload`.
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
/// Set by `spider dev --port N`: the port listen() uses instead of the
/// app's own.
pub const port_env_name = "SPIDER_DEV_PORT";
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
    \\  function reload() { if (!leaving) { leaving = true; location.reload(); } }
    \\  function connect() {
    \\    var sock = new WebSocket(url);
    \\    sock.onmessage = function (e) {
    \\      if (e.data === 'reload') return reload();
    \\      if (e.data.indexOf('id:') !== 0) return;
    \\      if (boot === null) { boot = e.data; return; }
    \\      if (e.data !== boot) reload();
    \\    };
    \\    sock.onclose = function () { if (!leaving) setTimeout(connect, 150); };
    \\  }
    \\  connect();
    \\})();
    \\
;

/// `Config.dev_reload` as a decision: an explicit value wins, otherwise the
/// environment. Always false in a release build. Called once, by listen().
pub fn resolve(configured: ?bool) bool {
    if (!compiled_in) return false;
    const from_env = env.get(env_name);
    // `spider dev` puts the path of its reload file in the variable.
    if (from_env) |value| {
        if (reload_file == null and std.fs.path.isAbsolute(value)) reload_file = value;
    }
    return configured orelse (from_env != null);
}

/// The port `spider dev --port N` asked for, if any. Never in a release
/// build.
pub fn portOverride() ?u16 {
    if (!compiled_in) return null;
    return parsePort(env.get(port_env_name) orelse return null);
}

pub fn parsePort(text: []const u8) ?u16 {
    const port = std.fmt.parseInt(u16, std.mem.trim(u8, text, " \t\r\n"), 10) catch return null;
    return if (port == 0) null else port;
}

/// The file `spider dev` rewrites to ask for a reload without replacing the
/// process. Null: no such requests (the app was not started by `spider dev`).
var reload_file: ?[]const u8 = null;

/// Tests: where the socket looks for reload requests.
pub fn setReloadFile(path: ?[]const u8) void {
    reload_file = path;
}

/// What the reload file holds now ("" when there is none). Any change is a
/// request.
fn reloadRequest(io: std.Io, buf: []u8) []const u8 {
    const path = reload_file orelse return "";
    return std.Io.Dir.cwd().readFile(io, path, buf) catch "";
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

const poll_ms = 100;
/// A write is the only way to find out the browser went away (the client
/// sends nothing): one every this many polls.
const ping_every = 20;

/// The WebSocket: sends `id:<boot id>`, then `reload` each time `spider
/// dev` asks for one, until the client is gone or this process ends.
/// Returns false when the request was not a WebSocket upgrade (nothing was
/// written).
pub fn serveSocket(
    io: std.Io,
    stream: std.Io.net.Stream,
    arena: std.mem.Allocator,
    headers: *const std.StringHashMapUnmanaged([]const u8),
) bool {
    var server = ws.Server.init(stream, io, arena);
    const upgraded = server.handshake(arena, headers) catch return true;
    if (!upgraded) return false;

    var hello_buf: [3 + 16]u8 = undefined;
    const hello = std.fmt.bufPrint(&hello_buf, "id:{s}", .{bootId(io)}) catch unreachable;
    server.sendText(hello) catch return true;

    var seen_buf: [64]u8 = undefined;
    var seen_len = reloadRequest(io, &seen_buf).len;
    var polls: u32 = 0;
    while (true) {
        std.Io.sleep(io, .fromMilliseconds(poll_ms), .awake) catch return true;
        var now_buf: [64]u8 = undefined;
        const now = reloadRequest(io, &now_buf);
        if (!std.mem.eql(u8, now, seen_buf[0..seen_len])) {
            @memcpy(seen_buf[0..now.len], now);
            seen_len = now.len;
            server.sendText("reload") catch return true;
            continue;
        }
        polls += 1;
        if (polls % ping_every == 0) server.sendText("ping") catch return true;
    }
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

test "script: same origin, wss on https, reloads on a different boot id or on request" {
    try std.testing.expect(std.mem.indexOf(u8, script, "location.host + '" ++ socket_path ++ "'") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "'wss://' : 'ws://'") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "e.data !== boot") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "e.data === 'reload'") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "http://") == null);
}

test "parsePort: a port number, nothing else" {
    try std.testing.expectEqual(@as(?u16, 4000), parsePort("4000"));
    try std.testing.expectEqual(@as(?u16, 4000), parsePort(" 4000\n"));
    try std.testing.expectEqual(@as(?u16, null), parsePort("0"));
    try std.testing.expectEqual(@as(?u16, null), parsePort("70000"));
    try std.testing.expectEqual(@as(?u16, null), parsePort("http"));
    try std.testing.expectEqual(@as(?u16, null), parsePort(""));
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
