const std = @import("std");
const Response = @import("../core/context.zig").Response;

pub const StaticConfig = struct {
    dir: []const u8 = "./public",
    prefix: []const u8 = "/",
};

pub fn contentType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".html")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, ext, ".css")) return "text/css";
    if (std.mem.eql(u8, ext, ".js")) return "application/javascript";
    if (std.mem.eql(u8, ext, ".json")) return "application/json";
    if (std.mem.eql(u8, ext, ".webmanifest")) return "application/manifest+json";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".jpg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".gif")) return "image/gif";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".ico")) return "image/x-icon";
    if (std.mem.eql(u8, ext, ".woff")) return "font/woff";
    if (std.mem.eql(u8, ext, ".woff2")) return "font/woff2";
    if (std.mem.eql(u8, ext, ".ttf")) return "font/ttf";
    if (std.mem.eql(u8, ext, ".pdf")) return "application/pdf";
    if (std.mem.eql(u8, ext, ".zip")) return "application/zip";
    if (std.mem.eql(u8, ext, ".webp")) return "image/webp";
    if (std.mem.eql(u8, ext, ".mp4")) return "video/mp4";
    if (std.mem.eql(u8, ext, ".mp3")) return "audio/mpeg";
    return "application/octet-stream";
}

/// What of the request affects caching.
pub const Request = struct {
    /// The URL's query string (without '?').
    query: ?[]const u8 = null,
    /// The If-None-Match header.
    if_none_match: ?[]const u8 = null,
};

/// Adds caching to a static file response: an ETag from the content
/// always; `Cache-Control: public, max-age=31536000, immutable` when the URL
/// carries a version (`?v=...`, e.g. from an asset_url helper: the URL
/// changes when the file does), `no-cache` otherwise (the browser
/// revalidates and gets 304 while the ETag matches — so sw.js, HTML and
/// unversioned assets never go stale). A matching If-None-Match is 304
/// with no body.
pub fn withCache(arena: std.mem.Allocator, r: Response, req: Request) !Response {
    const body = r.body orelse "";
    const etag = try std.fmt.allocPrint(arena, "\"{x:0>16}\"", .{std.hash.Wyhash.hash(0, body)});
    const versioned = if (req.query) |q| hasParam(q, "v") else false;
    const headers = try arena.alloc([2][]const u8, 2);
    headers[0] = .{ "ETag", etag };
    headers[1] = .{ "Cache-Control", if (versioned) "public, max-age=31536000, immutable" else "no-cache" };
    var out = r;
    out.headers = headers;
    if (req.if_none_match) |inm| {
        if (etagListHas(inm, etag)) {
            out.status = .not_modified;
            out.body = "";
        }
    }
    return out;
}

fn hasParam(query: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const key = if (std.mem.indexOfScalar(u8, pair, '=')) |eq| pair[0..eq] else pair;
        if (std.mem.eql(u8, key, name)) return true;
    }
    return false;
}

fn etagListHas(list: []const u8, etag: []const u8) bool {
    if (std.mem.eql(u8, std.mem.trim(u8, list, " "), "*")) return true;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        var tag = std.mem.trim(u8, raw, " ");
        if (std.mem.startsWith(u8, tag, "W/")) tag = tag[2..];
        if (std.mem.eql(u8, tag, etag)) return true;
    }
    return false;
}

pub fn serve(
    io: std.Io,
    arena: std.mem.Allocator,
    config: StaticConfig,
    request_path: []const u8,
    req: Request,
) !?Response {
    if (config.dir.len == 0) return null; // static files off (Config.static_dir = null)
    if (!std.mem.startsWith(u8, request_path, config.prefix)) return null;

    const after_prefix = request_path[config.prefix.len..];

    if (std.mem.indexOf(u8, after_prefix, "..") != null) return null;

    const relative = if (after_prefix.len > 0 and after_prefix[0] == '/')
        after_prefix[1..]
    else
        after_prefix;

    const r = (try serveFile(io, arena, config.dir, relative)) orelse return null;
    return try withCache(arena, r, req);
}

fn serveFile(
    io: std.Io,
    arena: std.mem.Allocator,
    dir: []const u8,
    relative_path: []const u8,
) !?Response {
    const file_path = if (relative_path.len == 0)
        try std.fmt.allocPrint(arena, "{s}/index.html", .{dir})
    else
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, relative_path });

    if (std.mem.indexOf(u8, file_path, "..") != null) return null;

    const content = std.Io.Dir.cwd().readFileAlloc(
        io,
        file_path,
        arena,
        .limited(10 * 1024 * 1024),
    ) catch |err| {
        if (err == error.FileNotFound or err == error.IsDir) return null;
        return err;
    };

    return Response{
        .status = .ok,
        .body = content,
        .content_type = contentType(file_path),
        .headers = &.{},
    };
}

test "contentType: web app manifest" {
    try std.testing.expectEqualStrings("application/manifest+json", contentType("/manifest.webmanifest"));
    try std.testing.expectEqualStrings("application/javascript", contentType("/sw.js"));
}

fn headerValue(r: Response, name: []const u8) ?[]const u8 {
    for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h[0], name)) return h[1];
    return null;
}

test "cacheHeaders: versioned URL is immutable for a year, others revalidate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try withCache(a, .{ .status = .ok, .body = "body", .content_type = "text/css" }, .{ .query = "v=1a2b3c4d" });
    try std.testing.expectEqualStrings("public, max-age=31536000, immutable", headerValue(v, "Cache-Control").?);
    const etag = headerValue(v, "ETag").?;
    try std.testing.expect(etag.len > 2 and etag[0] == '"');
    const plain = try withCache(a, .{ .status = .ok, .body = "body", .content_type = "text/css" }, .{ .query = "x=1" });
    try std.testing.expectEqualStrings("no-cache", headerValue(plain, "Cache-Control").?);
    try std.testing.expectEqualStrings(etag, headerValue(plain, "ETag").?);
    const changed = try withCache(a, .{ .status = .ok, .body = "other", .content_type = "text/css" }, .{});
    try std.testing.expect(!std.mem.eql(u8, etag, headerValue(changed, "ETag").?));
}

test "cacheHeaders: If-None-Match with the current ETag is 304 without a body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try withCache(a, .{ .status = .ok, .body = "body", .content_type = "text/css" }, .{});
    const etag = headerValue(first, "ETag").?;
    const again = try withCache(a, .{ .status = .ok, .body = "body", .content_type = "text/css" }, .{ .if_none_match = etag });
    try std.testing.expectEqual(std.http.Status.not_modified, again.status);
    try std.testing.expectEqualStrings("", again.body.?);
    try std.testing.expectEqualStrings(etag, headerValue(again, "ETag").?);
    const list = try withCache(a, .{ .status = .ok, .body = "body", .content_type = "text/css" }, .{ .if_none_match = try std.fmt.allocPrint(a, "\"x\", {s}", .{etag}) });
    try std.testing.expectEqual(std.http.Status.not_modified, list.status);
    const stale = try withCache(a, .{ .status = .ok, .body = "body", .content_type = "text/css" }, .{ .if_none_match = "\"old\"" });
    try std.testing.expectEqual(std.http.Status.ok, stale.status);
}

test "serve: a file under the static dir comes with cache headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app.css", .data = "body{}" });
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const r = (try serve(std.testing.io, a, .{ .dir = dir, .prefix = "/" }, "/app.css", .{ .query = "v=9" })).?;
    try std.testing.expectEqualStrings("body{}", r.body.?);
    try std.testing.expectEqualStrings("public, max-age=31536000, immutable", headerValue(r, "Cache-Control").?);
    try std.testing.expect((try serve(std.testing.io, a, .{ .dir = dir, .prefix = "/" }, "/missing.css", .{})) == null);
}

test "serve: an empty static dir (Config.static_dir = null) serves nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try serve(std.testing.io, arena.allocator(), .{ .dir = "", .prefix = "/" }, "/index.html", .{})) == null);
}
