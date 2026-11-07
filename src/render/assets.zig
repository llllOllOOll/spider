//! `{ asset_url("css/app.css") }` in a template: the file's URL with a
//! version taken from its content, `/css/app.css?v=<hash>`. The static
//! files answer such a URL with `Cache-Control: immutable` for a year
//! (modules/static.zig): the browser keeps the file and never asks again,
//! and a new content is a new URL. An app's own `asset_url` in its
//! `template_helpers` module takes precedence.

const std = @import("std");
const builtin = @import("builtin");

/// Where the files are and the server's Io: set by `listen()`. Before it
/// (a template rendered alone), `asset_url` gives the URL with no version.
var static_dir: []const u8 = "";
var url_prefix: []const u8 = "/";
var io_set: ?std.Io = null;

/// A release build hashes a file once: its files do not change while it
/// runs. A Debug build (`spider dev`) reads the file on every call, so an
/// edit shows at once.
var keep_versions: bool = builtin.mode != .debug;

const Cache = struct {
    lock: std.atomic.Mutex = .unlocked,
    map: std.StringHashMapUnmanaged([16]u8) = .empty,
};
var cache: Cache = .{};

fn lock() void {
    while (!cache.lock.tryLock()) std.atomic.spinLoopHint();
}

// internal: called by listen() with the static files' directory and URL
// prefix (StaticConfig) and the server's Io.
pub fn configure(io: std.Io, dir: []const u8, prefix: []const u8) void {
    io_set = io;
    static_dir = dir;
    url_prefix = prefix;
}

// internal: the renderer's built-in `asset_url(path)`: the URL of `path`
// (relative to the static directory, a leading "/" allowed) with `?v=`
// and 16 hex digits of the content's hash; without `?v=` when the file
// cannot be read (no static directory, a wrong name): the page still
// works, only without the long cache. Allocated with `alc`.
pub fn url(alc: std.mem.Allocator, path_arg: []const u8) ![]const u8 {
    const path = std.mem.trimStart(u8, path_arg, "/");
    const sep: []const u8 = if (std.mem.endsWith(u8, url_prefix, "/")) "" else "/";
    const version = versionOf(alc, path) orelse
        return std.fmt.allocPrint(alc, "{s}{s}{s}", .{ url_prefix, sep, path });
    return std.fmt.allocPrint(alc, "{s}{s}{s}?v={s}", .{ url_prefix, sep, path, &version });
}

fn versionOf(alc: std.mem.Allocator, path: []const u8) ?[16]u8 {
    const io = io_set orelse return null;
    if (static_dir.len == 0 or path.len == 0 or std.mem.indexOf(u8, path, "..") != null) return null;
    if (keep_versions) {
        lock();
        defer cache.lock.unlock();
        if (cache.map.get(path)) |v| return v;
    }
    const file_path = std.fmt.allocPrint(alc, "{s}/{s}", .{ static_dir, path }) catch return null;
    defer alc.free(file_path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, file_path, alc, .limited(64 * 1024 * 1024)) catch return null;
    defer alc.free(content);
    var version: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&version, "{x:0>16}", .{std.hash.Wyhash.hash(0, content)}) catch unreachable;
    if (keep_versions) {
        const gpa = std.heap.smp_allocator;
        lock();
        defer cache.lock.unlock();
        if (!cache.map.contains(path)) {
            const key = gpa.dupe(u8, path) catch return version;
            cache.map.put(gpa, key, version) catch gpa.free(key);
        }
    }
    return version;
}

test "url: the content's version, a new one when the file changes; none for a missing file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "css");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "css/app.css", .data = "body{}" });
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(dir);
    const saved = .{ io_set, static_dir, url_prefix, keep_versions };
    defer {
        io_set, static_dir, url_prefix, keep_versions = saved;
    }
    configure(std.testing.io, dir, "/");
    keep_versions = false;

    const first = try url(a, "css/app.css");
    defer a.free(first);
    try std.testing.expect(std.mem.startsWith(u8, first, "/css/app.css?v="));
    try std.testing.expectEqual(@as(usize, "/css/app.css?v=".len + 16), first.len);
    const slash = try url(a, "/css/app.css");
    defer a.free(slash);
    try std.testing.expectEqualStrings(first, slash);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "css/app.css", .data = "body{color:red}" });
    const edited = try url(a, "css/app.css");
    defer a.free(edited);
    try std.testing.expect(!std.mem.eql(u8, first, edited));

    const missing = try url(a, "css/nope.css");
    defer a.free(missing);
    try std.testing.expectEqualStrings("/css/nope.css", missing);
    const up = try url(a, "../secret");
    defer a.free(up);
    try std.testing.expectEqualStrings("/../secret", up);

    configure(std.testing.io, dir, "/assets");
    const prefixed = try url(a, "css/app.css");
    defer a.free(prefixed);
    try std.testing.expect(std.mem.startsWith(u8, prefixed, "/assets/css/app.css?v="));
}

test "url: a release build hashes a file once" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "kept.js", .data = "let a" });
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(dir);
    const saved = .{ io_set, static_dir, url_prefix, keep_versions };
    defer {
        io_set, static_dir, url_prefix, keep_versions = saved;
    }
    configure(std.testing.io, dir, "/");
    keep_versions = true;

    const first = try url(a, "kept.js");
    defer a.free(first);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "kept.js", .data = "let b" });
    const again = try url(a, "kept.js");
    defer a.free(again);
    try std.testing.expectEqualStrings(first, again);
}

test "url: before listen() there is no directory: the plain URL" {
    const a = std.testing.allocator;
    const saved = .{ io_set, static_dir, url_prefix, keep_versions };
    defer {
        io_set, static_dir, url_prefix, keep_versions = saved;
    }
    io_set = null;
    url_prefix = "/";
    const plain = try url(a, "app.css");
    defer a.free(plain);
    try std.testing.expectEqualStrings("/app.css", plain);
}
