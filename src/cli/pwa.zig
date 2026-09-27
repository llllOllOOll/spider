//! `spider add pwa` / `spider remove pwa` (and `spider new --pwa`).
//!
//! A PWA here is static files under public/ — served before routing, with
//! no login, which is what browsers need for them — plus a marked block in
//! the layouts' <head>:
//!
//!   public/manifest.webmanifest   name, start_url, scope, display, icons (any + maskable)
//!   public/sw.js                  offline fallback for page loads + push notifications
//!   public/offline.html           shown when a page can't load
//!   public/js/pwa.js              registers sw.js; $store.pwa.install() prompt
//!   public/pwa/*.png              192/512 icons, 512 maskable, apple-touch-icon
//!
//! Removing isn't deleting: browsers that installed the app keep running
//! the old service worker, so `remove` swaps sw.js for one that clears its
//! caches and unregisters itself.

const std = @import("std");
const fs_utils = @import("fs_utils.zig");

const manifest_tmpl = @embedFile("templates/pwa/manifest.webmanifest.template");
const sw_tmpl = @embedFile("templates/pwa/sw.js.template");
const sw_remove_tmpl = @embedFile("templates/pwa/sw_remove.js.template");
const pwa_js_tmpl = @embedFile("templates/pwa/pwa.js.template");
const offline_tmpl = @embedFile("templates/pwa/offline.html.template");

const icons = [_]struct { []const u8, []const u8 }{
    .{ "public/pwa/icon-192.png", @embedFile("assets/pwa/icon-192.png") },
    .{ "public/pwa/icon-512.png", @embedFile("assets/pwa/icon-512.png") },
    .{ "public/pwa/icon-maskable-512.png", @embedFile("assets/pwa/icon-maskable-512.png") },
    .{ "public/pwa/apple-touch-icon.png", @embedFile("assets/pwa/apple-touch-icon.png") },
};

/// Layouts that get the <head> block (the ones `spider new` generates).
const layouts = [_][]const u8{ "src/shared/templates/layout.html", "src/shared/templates/app.html" };

const head_begin = "<!-- spider:pwa -->";
const head_end = "<!-- /spider:pwa -->";
const head_block =
    \\    <!-- spider:pwa -->
    \\    <link rel="manifest" href="/manifest.webmanifest">
    \\    <meta name="theme-color" content="#1d232a">
    \\    <link rel="apple-touch-icon" href="/pwa/apple-touch-icon.png">
    \\    <script defer src="/js/pwa.js"></script>
    \\    <!-- /spider:pwa -->
    \\
;

/// `layout` with the PWA block in <head>: before the Alpine <script> (both
/// are deferred, so pwa.js runs first and its alpine:init listener is in
/// place), else before </head>. Null when it's already there.
pub fn withHead(allocator: std.mem.Allocator, layout: []const u8) !?[]u8 {
    if (std.mem.indexOf(u8, layout, head_begin) != null) return null;
    const anchor = std.mem.indexOf(u8, layout, "alpine.min.js") orelse std.mem.indexOf(u8, layout, "</head>") orelse return error.NoHead;
    var line_start = anchor;
    while (line_start > 0 and layout[line_start - 1] != '\n') line_start -= 1;
    return try std.mem.concat(allocator, u8, &.{ layout[0..line_start], head_block, layout[line_start..] });
}

/// `layout` without the PWA block, or null when it has none.
pub fn withoutHead(allocator: std.mem.Allocator, layout: []const u8) !?[]u8 {
    const begin = std.mem.indexOf(u8, layout, head_begin) orelse return null;
    const end_at = std.mem.indexOfPos(u8, layout, begin, head_end) orelse return null;
    var start = begin;
    while (start > 0 and layout[start - 1] != '\n') start -= 1;
    var end = end_at + head_end.len;
    if (end < layout.len and layout[end] == '\n') end += 1;
    return try std.mem.concat(allocator, u8, &.{ layout[0..start], layout[end..] });
}

fn render(allocator: std.mem.Allocator, tmpl: []const u8, app_name: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, tmpl, "{{app_name}}", app_name);
}

/// The app's name from build.zig.zon (`.name = .myapp,`).
pub fn appNameFromZon(zon: []const u8) ?[]const u8 {
    const key = ".name = .";
    const at = std.mem.indexOf(u8, zon, key) orelse return null;
    const rest = zon[at + key.len ..];
    const end = std.mem.indexOfAny(u8, rest, ",\n ") orelse return null;
    return if (end == 0) null else rest[0..end];
}

fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

/// Writes the PWA files and the layouts' <head> block. `prefix` only
/// decorates the "create" lines (spider new prints paths under the app).
pub fn add(io: std.Io, allocator: std.mem.Allocator, root: std.Io.Dir, app_name: []const u8, prefix: []const u8) !void {
    const files = [_]struct { []const u8, []const u8 }{
        .{ "public/manifest.webmanifest", manifest_tmpl },
        .{ "public/sw.js", sw_tmpl },
        .{ "public/offline.html", offline_tmpl },
        .{ "public/js/pwa.js", pwa_js_tmpl },
    };
    for (files) |f| {
        const content = try render(allocator, f[1], app_name);
        defer allocator.free(content);
        try fs_utils.writeFile(io, root, f[0], content);
        say("  create  {s}{s}\n", .{ prefix, f[0] });
    }
    for (icons) |f| {
        try fs_utils.writeFile(io, root, f[0], f[1]);
        say("  create  {s}{s}\n", .{ prefix, f[0] });
    }
    var touched: usize = 0;
    for (layouts) |path| {
        const text = root.readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch continue;
        defer allocator.free(text);
        const updated = withHead(allocator, text) catch |err| {
            say("warning: {s}: no <head> to add the PWA tags to ({s})\n", .{ path, @errorName(err) });
            continue;
        } orelse continue;
        defer allocator.free(updated);
        try fs_utils.writeFile(io, root, path, updated);
        say("  update  {s}{s} (<head>: manifest, theme-color, pwa.js)\n", .{ prefix, path });
        touched += 1;
    }
    if (touched == 0) say("warning: no layout updated; add the <!-- spider:pwa --> block to your layout's <head> by hand:\n{s}", .{head_block});
}

pub fn remove(io: std.Io, allocator: std.mem.Allocator, root: std.Io.Dir, app_name: []const u8) !void {
    const sw = try render(allocator, sw_remove_tmpl, app_name);
    defer allocator.free(sw);
    try fs_utils.writeFile(io, root, "public/sw.js", sw);
    say("  update  public/sw.js (unregisters itself in browsers that installed the app)\n", .{});
    for ([_][]const u8{ "public/manifest.webmanifest", "public/offline.html", "public/js/pwa.js" }) |path| {
        root.deleteFile(io, path) catch continue;
        say("  delete  {s}\n", .{path});
    }
    root.deleteTree(io, "public/pwa") catch {};
    say("  delete  public/pwa/\n", .{});
    for (layouts) |path| {
        const text = root.readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch continue;
        defer allocator.free(text);
        const updated = (try withoutHead(allocator, text)) orelse continue;
        defer allocator.free(updated);
        try fs_utils.writeFile(io, root, path, updated);
        say("  update  {s} (removed the PWA <head> block)\n", .{path});
    }
    say("\nKeep public/sw.js for a few weeks — until your users have visited again —\nthen delete it.\n", .{});
}

/// `spider add <what>` / `spider remove <what>`.
pub fn run(io: std.Io, allocator: std.mem.Allocator, adding: bool, args: []const []const u8) !u8 {
    const verb = if (adding) "add" else "remove";
    if (args.len != 1 or !std.mem.eql(u8, args[0], "pwa")) {
        say("usage: spider {s} pwa   (see `spider {s} --help`)\n", .{ verb, verb });
        return 2;
    }
    const root = try fs_utils.findProjectRoot(io);
    const zon = try root.readFileAlloc(io, "build.zig.zon", allocator, .limited(64 * 1024));
    defer allocator.free(zon);
    const app_name = appNameFromZon(zon) orelse "app";

    if (adding) {
        root.access(io, "src/shared/templates/layout.html", .{}) catch {
            say("error: src/shared/templates/layout.html not found — a PWA needs an app with HTML views\n", .{});
            return 2;
        };
        if (root.access(io, "public/manifest.webmanifest", .{})) |_| {
            say("error: public/manifest.webmanifest already exists: the app already has a PWA\n", .{});
            return 2;
        } else |_| {}
        try add(io, allocator, root, app_name, "");
        say(
            \\
            \\PWA added. Check it in Chrome DevTools > Application > Manifest / Service workers.
            \\ - Replace public/pwa/*.png with your icons (the maskable one keeps the logo
            \\   inside the center 80%), and set name/colors in public/manifest.webmanifest.
            \\ - Install button: <button x-show="$store.pwa.canInstall" @click="$store.pwa.install()">Install</button>
            \\ - Service workers need HTTPS (localhost is exempt).
            \\
        , .{});
        return 0;
    }

    root.access(io, "public/manifest.webmanifest", .{}) catch {
        say("error: no public/manifest.webmanifest: the app has no PWA to remove\n", .{});
        return 2;
    };
    try remove(io, allocator, root, app_name);
    return 0;
}

const t = std.testing;

const sample_layout =
    \\<head>
    \\    <link rel="stylesheet" href="/css/app.css">
    \\    <script defer src="/js/stores.js"></script>
    \\    <script defer src="/js/alpine.min.js"></script>
    \\</head>
    \\<body></body>
    \\
;

test "withHead: the block goes before the Alpine script, once; withoutHead undoes it" {
    const a = t.allocator;
    const with = (try withHead(a, sample_layout)).?;
    defer a.free(with);
    const block_at = std.mem.indexOf(u8, with, head_begin).?;
    try t.expect(block_at < std.mem.indexOf(u8, with, "alpine.min.js").?);
    try t.expect(block_at > std.mem.indexOf(u8, with, "stores.js").?);
    try t.expect(std.mem.indexOf(u8, with, "<link rel=\"manifest\" href=\"/manifest.webmanifest\">") != null);
    try t.expect((try withHead(a, with)) == null);
    const without = (try withoutHead(a, with)).?;
    defer a.free(without);
    try t.expectEqualStrings(sample_layout, without);
    try t.expect((try withoutHead(a, sample_layout)) == null);
}

test "withHead: falls back to </head>; no <head> is an error" {
    const a = t.allocator;
    const with = (try withHead(a, "<head>\n<title>x</title>\n</head>\n")).?;
    defer a.free(with);
    try t.expect(std.mem.indexOf(u8, with, head_begin).? < std.mem.indexOf(u8, with, "</head>").?);
    try t.expectError(error.NoHead, withHead(a, "<body></body>"));
}

test "appNameFromZon" {
    try t.expectEqualStrings("myapp", appNameFromZon(".{\n    .name = .myapp,\n    .version = \"0.1.0\",").?);
    try t.expect(appNameFromZon(".{}") == null);
}

test "manifest: valid JSON with the fields installability needs" {
    const a = t.allocator;
    const m = try render(a, manifest_tmpl, "shop");
    defer a.free(m);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, m, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    for ([_][]const u8{ "id", "name", "short_name", "start_url", "scope", "display", "icons", "theme_color", "background_color" }) |k| try t.expect(o.get(k) != null);
    try t.expectEqualStrings("shop", o.get("name").?.string);
    var has_maskable = false;
    var has_512 = false;
    for (o.get("icons").?.array.items) |icon| {
        if (std.mem.eql(u8, icon.object.get("purpose").?.string, "maskable")) has_maskable = true;
        if (std.mem.eql(u8, icon.object.get("sizes").?.string, "512x512")) has_512 = true;
    }
    try t.expect(has_maskable and has_512);
}
