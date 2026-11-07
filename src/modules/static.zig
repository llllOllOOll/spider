//! Static file serving. The server does it by itself, before routing, for the
//! `static_dir` of the config (or `Server.staticDir` / `Server.staticAt`);
//! apps only see `StaticConfig`.

const std = @import("std");
const Response = @import("../core/context.zig").Response;

/// Where static files are read from and under which URL path they are
/// served. Apps set it through `Config.static_dir`, `Server.staticDir(dir)`
/// or `Server.staticAt(dir, prefix)`.
///
/// Files are answered before routing and before any middleware, to any
/// method: they are always public. The prefix itself serves `index.html`.
/// A path with `..` in it, or one that names no file, goes on to the
/// routes. The content type comes from the extension
/// (`application/octet-stream` when unknown). Every answer has an `ETag`
/// (a matching `If-None-Match` gets 304) and `Cache-Control: no-cache`, or
/// `public, max-age=31536000, immutable` when the URL has a `v` query
/// parameter (`/app.css?v=3`). Text files (CSS, JavaScript, SVG, JSON,
/// HTML, ...) of 1 KiB or more go gzipped to a client that accepts it,
/// with `Content-Encoding: gzip` and `Vary: Accept-Encoding`; each file is
/// compressed once and kept in memory until its content changes.
pub const StaticConfig = struct {
    /// The directory of the files, relative to the working directory.
    /// Empty: no static files.
    dir: []const u8 = "./public",
    /// The start of the URL paths answered from `dir`: with `/assets`,
    /// `/assets/app.css` is the file `app.css` of `dir`. It is compared as
    /// text: `/assets` also takes `/assets-old/x.css`, as the file
    /// `-old/x.css`.
    prefix: []const u8 = "/",
    /// The largest file served. A file is read whole into memory for each
    /// request that gets it, so this bounds what one request can take. A
    /// bigger file is not served (the request goes on to the routes, which
    /// answer 404) and the server logs which file and which limit. Set it
    /// with `static_max_file_bytes` in `spider.config.zig`.
    max_file_bytes: usize = 10 * 1024 * 1024,
};

// internal: the Content-Type for a file name, by its extension; `application/octet-stream` when unknown.
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

// internal: the part of a request `serve` needs.
// What of the request affects caching.
pub const Request = struct {
    /// The URL's query string (without '?').
    query: ?[]const u8 = null,
    /// The If-None-Match header.
    if_none_match: ?[]const u8 = null,
    /// Whether the Accept-Encoding header accepts gzip (see acceptsGzip).
    accept_gzip: bool = false,
};

// internal: whether an Accept-Encoding header value accepts gzip: `gzip`
// or `*`, unless its weight is zero (`gzip;q=0`).
pub fn acceptsGzip(accept_encoding: []const u8) bool {
    var it = std.mem.splitScalar(u8, accept_encoding, ',');
    while (it.next()) |item| {
        var parts = std.mem.splitScalar(u8, item, ';');
        const coding = std.mem.trim(u8, parts.first(), " \t");
        if (!std.ascii.eqlIgnoreCase(coding, "gzip") and !std.mem.eql(u8, coding, "*")) continue;
        var refused = false;
        while (parts.next()) |param| {
            const p = std.mem.trim(u8, param, " \t");
            if (p.len >= 2 and (p[0] == 'q' or p[0] == 'Q') and p[1] == '=') {
                const w = std.fmt.parseFloat(f32, p[2..]) catch 1;
                refused = w <= 0;
            }
        }
        if (!refused) return true;
    }
    return false;
}

/// Files smaller than this go as they are: gzip saves little on them.
const min_gzip_bytes: usize = 1024;

/// What compresses well: text. Images, fonts, archives and media already
/// are compressed.
fn compressible(content_type: []const u8) bool {
    const types = [_][]const u8{ "text/", "application/javascript", "application/json", "application/manifest+json", "image/svg+xml", "image/x-icon" };
    for (types) |t| if (std.mem.startsWith(u8, content_type, t)) return true;
    return false;
}

/// The compressed files, by the hash of their content: a file that changes
/// gets a new entry. Bounded: past `gzip_cache_limit` bytes it starts over.
const GzCache = struct {
    lock: std.atomic.Mutex = .unlocked,
    map: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    bytes: usize = 0,
};
var gz_cache: GzCache = .{};
const gzip_cache_limit: usize = 64 * 1024 * 1024;

fn cacheLock() void {
    while (!gz_cache.lock.tryLock()) std.atomic.spinLoopHint();
}

/// `body` gzipped, from the cache or compressed now (and kept). Memory
/// that lives as long as the process; the result must not be freed.
fn gzipped(body: []const u8, hash: u64) ![]const u8 {
    cacheLock();
    const hit = gz_cache.map.get(hash);
    gz_cache.lock.unlock();
    if (hit) |bytes| return bytes;

    const gpa = std.heap.smp_allocator;
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, body.len / 2 + 64);
    defer out.deinit();
    var compressor = try std.compress.flate.Compress.init(&out.writer, window, .gzip, .best);
    try compressor.writer.writeAll(body);
    try compressor.finish();
    const bytes = try gpa.dupe(u8, out.written());

    cacheLock();
    defer gz_cache.lock.unlock();
    // Another request compressed it meanwhile: keep that one.
    if (gz_cache.map.get(hash)) |kept| {
        gpa.free(bytes);
        return kept;
    }
    if (gz_cache.bytes + bytes.len > gzip_cache_limit) {
        var it = gz_cache.map.valueIterator();
        while (it.next()) |v| gpa.free(v.*);
        gz_cache.map.clearRetainingCapacity();
        gz_cache.bytes = 0;
    }
    gz_cache.map.put(gpa, hash, bytes) catch {
        gpa.free(bytes);
        return error.OutOfMemory;
    };
    gz_cache.bytes += bytes.len;
    return bytes;
}

// internal: the caching step of `serve`.
// Adds caching to a static file response: an ETag from the content
// always; `Cache-Control: public, max-age=31536000, immutable` when the URL
// carries a version (`?v=...`, e.g. from an asset_url helper: the URL
// changes when the file does), `no-cache` otherwise (the browser
// revalidates and gets 304 while the ETag matches — so sw.js, HTML and
// unversioned assets never go stale). A matching If-None-Match is 304
// with no body.
pub fn withCache(arena: std.mem.Allocator, r: Response, req: Request) !Response {
    const body = r.body orelse "";
    const hash = std.hash.Wyhash.hash(0, body);
    const etag = try std.fmt.allocPrint(arena, "\"{x:0>16}\"", .{hash});
    // The gzipped bytes are another representation: another ETag (RFC 9110
    // 8.8.3), from which "-gzip" is taken off to compare.
    const text = compressible(r.content_type);
    const gzip = text and req.accept_gzip and body.len >= min_gzip_bytes;
    const gz_etag = try std.fmt.allocPrint(arena, "\"{x:0>16}-gzip\"", .{hash});
    const versioned = if (req.query) |q| hasParam(q, "v") else false;
    var headers: std.ArrayList([2][]const u8) = try .initCapacity(arena, 4);
    headers.appendAssumeCapacity(.{ "ETag", if (gzip) gz_etag else etag });
    headers.appendAssumeCapacity(.{ "Cache-Control", if (versioned) "public, max-age=31536000, immutable" else "no-cache" });
    if (text) headers.appendAssumeCapacity(.{ "Vary", "Accept-Encoding" });
    var out = r;
    if (req.if_none_match) |inm| {
        if (etagListHas(inm, etag) or etagListHas(inm, gz_etag)) {
            out.status = .not_modified;
            out.body = "";
            out.headers = headers.items;
            return out;
        }
    }
    if (gzip) {
        out.body = try gzipped(body, hash);
        headers.appendAssumeCapacity(.{ "Content-Encoding", "gzip" });
    }
    out.headers = headers.items;
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

// internal: called by the server for each request before routing.
// The response for `request_path`, or null when no file answers it.
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

    const r = (try serveFile(io, arena, config.dir, relative, config.max_file_bytes)) orelse return null;
    return try withCache(arena, r, req);
}

fn serveFile(
    io: std.Io,
    arena: std.mem.Allocator,
    dir: []const u8,
    relative_path: []const u8,
    max_file_bytes: usize,
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
        // The reader refuses a file that reaches its limit: one more byte
        // makes `max_file_bytes` itself the largest size served.
        .limited(max_file_bytes +| 1),
    ) catch |err| {
        if (err == error.FileNotFound or err == error.IsDir) return null;
        if (err == error.StreamTooLong) return error.StaticFileTooLarge;
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

test "serve: a file over max_file_bytes is error.StaticFileTooLarge; the limit can be raised" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const big: [2000]u8 = @splat('x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "video.mp4", .data = &big });
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try std.testing.expectError(
        error.StaticFileTooLarge,
        serve(std.testing.io, a, .{ .dir = dir, .prefix = "/", .max_file_bytes = 1000 }, "/video.mp4", .{}),
    );
    const r = (try serve(std.testing.io, a, .{ .dir = dir, .prefix = "/", .max_file_bytes = 2000 }, "/video.mp4", .{})).?;
    try std.testing.expectEqual(@as(usize, 2000), r.body.?.len);
    // The default is 10 MiB.
    try std.testing.expectEqual(@as(usize, 10 * 1024 * 1024), (StaticConfig{}).max_file_bytes);
}

fn gunzip(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(data);
    var gz: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
    return gz.reader.allocRemaining(a, .unlimited);
}

test "serve: a text file is gzipped for a client that accepts it, with Vary and its own ETag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const css: [4000]u8 = @splat('a');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app.css", .data = &css });
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const cfg: StaticConfig = .{ .dir = dir, .prefix = "/" };

    const gz = (try serve(std.testing.io, a, cfg, "/app.css", .{ .accept_gzip = true })).?;
    try std.testing.expectEqualStrings("gzip", headerValue(gz, "Content-Encoding").?);
    try std.testing.expectEqualStrings("Accept-Encoding", headerValue(gz, "Vary").?);
    try std.testing.expect(gz.body.?.len < css.len);
    try std.testing.expectEqualStrings(&css, try gunzip(a, gz.body.?));
    const gz_etag = headerValue(gz, "ETag").?;
    try std.testing.expect(std.mem.endsWith(u8, gz_etag, "-gzip\""));

    // Not accepted: the file as it is, still with Vary (a cache must not mix them).
    const plain = (try serve(std.testing.io, a, cfg, "/app.css", .{})).?;
    try std.testing.expect(headerValue(plain, "Content-Encoding") == null);
    try std.testing.expectEqualStrings("Accept-Encoding", headerValue(plain, "Vary").?);
    try std.testing.expectEqualStrings(&css, plain.body.?);
    const plain_etag = headerValue(plain, "ETag").?;
    try std.testing.expect(!std.mem.eql(u8, plain_etag, gz_etag));

    // Either ETag revalidates the same content: 304, nothing to send.
    for ([_][]const u8{ gz_etag, plain_etag }) |etag| {
        const again = (try serve(std.testing.io, a, cfg, "/app.css", .{ .accept_gzip = true, .if_none_match = etag })).?;
        try std.testing.expectEqual(std.http.Status.not_modified, again.status);
        try std.testing.expectEqualStrings("", again.body.?);
        try std.testing.expectEqualStrings(gz_etag, headerValue(again, "ETag").?);
    }

    // Compressed once: the next request gets the same bytes.
    const second = (try serve(std.testing.io, a, cfg, "/app.css", .{ .accept_gzip = true })).?;
    try std.testing.expectEqual(gz.body.?.ptr, second.body.?.ptr);
}

test "serve: images and small files are never gzipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const big: [4000]u8 = @splat('b');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "logo.png", .data = &big });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tiny.js", .data = "let a = 1;" });
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const cfg: StaticConfig = .{ .dir = dir, .prefix = "/" };

    const png = (try serve(std.testing.io, a, cfg, "/logo.png", .{ .accept_gzip = true })).?;
    try std.testing.expect(headerValue(png, "Content-Encoding") == null);
    try std.testing.expect(headerValue(png, "Vary") == null);
    const tiny = (try serve(std.testing.io, a, cfg, "/tiny.js", .{ .accept_gzip = true })).?;
    try std.testing.expect(headerValue(tiny, "Content-Encoding") == null);
    try std.testing.expectEqualStrings("let a = 1;", tiny.body.?);
}

test "acceptsGzip: the Accept-Encoding header, q=0 refuses" {
    try std.testing.expect(acceptsGzip("gzip, deflate, br"));
    try std.testing.expect(acceptsGzip("br;q=1.0, GZIP;q=0.5"));
    try std.testing.expect(acceptsGzip("*"));
    try std.testing.expect(!acceptsGzip("br, deflate"));
    try std.testing.expect(!acceptsGzip("gzip;q=0"));
    try std.testing.expect(!acceptsGzip(""));
}
