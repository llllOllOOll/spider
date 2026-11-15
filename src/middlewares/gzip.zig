//! `spider.gzip`: a middleware that compresses response bodies for the
//! clients that accept gzip.

const std = @import("std");
const Ctx = @import("../core/context.zig").Ctx;
const NextFn = @import("../core/context.zig").NextFn;
const Response = @import("../core/context.zig").Response;
const dev_reload = @import("../modules/dev_reload.zig");

const MIN_COMPRESS_BYTES: usize = 1024;

/// False for content types that are compressed already: images (SVG is
/// text and is compressed), video, audio, woff fonts, zip and gzip
/// archives, PDF and the Office formats (zip inside).
fn compressible(content_type: []const u8) bool {
    const ct = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, content_type, ';')) |i| content_type[0..i] else content_type, " \t");
    if (startsWithIgnoreCase(ct, "image/")) return std.ascii.eqlIgnoreCase(ct, "image/svg+xml");
    for ([_][]const u8{ "video/", "audio/", "font/woff", "application/zip", "application/gzip", "application/x-gzip", "application/pdf", "application/vnd.openxmlformats-", "application/x-7z", "application/x-rar", "application/x-bzip2", "application/zstd", "application/wasm" }) |prefix| {
        if (startsWithIgnoreCase(ct, prefix)) return false;
    }
    return true;
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// Whether the request's Accept-Encoding accepts gzip.
fn clientAcceptsGzip(headers: std.StringHashMapUnmanaged([]const u8)) bool {
    var iter = headers.iterator();
    while (iter.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "accept-encoding")) return acceptsGzip(entry.value_ptr.*);
    }
    return false;
}

/// An Accept-Encoding value read as RFC 9110 says: `gzip` (or `*` when gzip
/// is not named) with a q-value above 0. `gzip;q=0` is a refusal.
fn acceptsGzip(value: []const u8) bool {
    var gzip_q: ?bool = null;
    var star_q: ?bool = null;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        var parts = std.mem.splitScalar(u8, raw, ';');
        const coding = std.mem.trim(u8, parts.first(), " \t");
        var allowed = true;
        while (parts.next()) |param| {
            const p = std.mem.trim(u8, param, " \t");
            if (p.len >= 2 and (p[0] == 'q' or p[0] == 'Q') and p[1] == '=') allowed = !zeroQ(p[2..]);
        }
        if (std.ascii.eqlIgnoreCase(coding, "gzip") or std.ascii.eqlIgnoreCase(coding, "x-gzip")) {
            gzip_q = allowed;
        } else if (std.mem.eql(u8, coding, "*")) {
            star_q = allowed;
        }
    }
    return gzip_q orelse star_q orelse false;
}

/// "0", "0.", "0.0", "0.000": a q-value of zero.
fn zeroQ(q: []const u8) bool {
    const v = std.mem.trim(u8, q, " \t");
    if (v.len == 0 or v[0] != '0') return false;
    for (v[1..]) |ch| if (ch != '.' and ch != '0') return false;
    return true;
}

/// Compresses the response body with gzip when the request's
/// `Accept-Encoding` accepts gzip (`gzip;q=0` refuses it) and the body has
/// at least 1024 bytes, and
/// adds `content-encoding: gzip` and `vary: accept-encoding`. Smaller bodies,
/// responses without a body, responses that already have a
/// `Content-Encoding`, formats that are compressed already (images but SVG,
/// video, audio, woff, zip, PDF, Office files) and streams (SSE, WebSocket)
/// pass unchanged, and so does a body gzip would not make smaller. The
/// compressed body is allocated in the request arena.
///
/// ```zig
/// server.use(spider.gzip)
/// ```
pub fn middleware(c: *Ctx, next: NextFn) anyerror!Response {
    // 1. Skip if client does not accept gzip
    if (!clientAcceptsGzip(c._headers)) {
        return next(c);
    }

    var resp = next(c) catch |err| return err;

    // 2. Skip raw (streaming) responses
    if (resp.raw) return resp;

    // 3. Skip responses without a body
    var body = resp.body orelse return resp;

    // A body that is already encoded (a precompressed file, a proxied
    // response) would be encoded twice: the client could not read it.
    for (resp.headers) |h| if (std.ascii.eqlIgnoreCase(h[0], "content-encoding")) return resp;
    // Formats that are compressed already gain nothing and cost CPU.
    if (!compressible(resp.content_type)) return resp;

    // Under `spider dev` the reload script goes into HTML pages. The server
    // adds it after the middlewares ran, where a page compressed here is
    // bytes it cannot read, so it is added now.
    if (dev_reload.compiled_in and c._dev_reload and dev_reload.isHtml(resp.content_type)) {
        body = dev_reload.inject(c.arena, body);
        resp.body = body;
    }

    // 4. Skip small payloads (diminishing returns)
    if (body.len < MIN_COMPRESS_BYTES) return resp;

    // 5. Allocate output buffer (gzip typically reduces size, but we allocate
    //    generously to handle pathological cases)
    const out_capacity = body.len + (body.len / 2) + 128;
    const output_buf = try c.arena.alloc(u8, out_capacity);
    var output_w = std.Io.Writer.fixed(output_buf);

    // 6. Compress using flate with gzip container
    var win_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(
        &output_w,
        &win_buf,
        .gzip,
        .fastest,
    );
    try compressor.writer.writeAll(body);
    try compressor.finish();

    const compressed_len = output_w.buffered().len;
    const compressed = output_buf[0..compressed_len];
    // Not smaller: the original goes.
    if (compressed_len >= body.len) return resp;

    // 7. Replace body
    resp.body = compressed;

    // 8. Append content-encoding and vary headers via arena-allocated slice
    const new_headers = try c.arena.alloc([2][]const u8, resp.headers.len + 2);
    @memcpy(new_headers[0..resp.headers.len], resp.headers);
    new_headers[resp.headers.len] = .{ "content-encoding", "gzip" };
    new_headers[resp.headers.len + 1] = .{ "vary", "accept-encoding" };
    resp.headers = new_headers;

    return resp;
}

const testing = std.testing;

const big_text: []const u8 = blk: {
    const word = "spider gzip test body ";
    @setEvalBranchQuota(10_000);
    var b: [word.len * 80]u8 = undefined;
    for (&b, 0..) |*x, i| x.* = word[i % word.len];
    const out = b;
    break :blk &out;
};

fn ctxWith(alc: std.mem.Allocator, accept: []const u8) !Ctx {
    var ctx = Ctx{ .request = undefined, .arena = alc, .params = .{} };
    try ctx._headers.put(alc, "accept-encoding", accept);
    return ctx;
}

fn header(resp: Response, name: []const u8) ?[]const u8 {
    for (resp.headers) |h| if (std.ascii.eqlIgnoreCase(h[0], name)) return h[1];
    return null;
}

fn count(resp: Response, name: []const u8) usize {
    var n: usize = 0;
    for (resp.headers) |h| n += @intFromBool(std.ascii.eqlIgnoreCase(h[0], name));
    return n;
}

test "gzip: a large text body is compressed, with Vary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = try ctxWith(arena.allocator(), "gzip, deflate, br");
    const resp = try middleware(&c, struct {
        fn n(_: *Ctx) anyerror!Response {
            return .{ .status = .ok, .body = big_text, .content_type = "text/plain" };
        }
    }.n);
    try testing.expectEqualStrings("gzip", header(resp, "content-encoding").?);
    try testing.expectEqualStrings("accept-encoding", header(resp, "vary").?);
    try testing.expect(resp.body.?.len < big_text.len);
}

test "gzip: a response that already has a Content-Encoding passes untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = try ctxWith(arena.allocator(), "gzip");
    const resp = try middleware(&c, struct {
        fn n(_: *Ctx) anyerror!Response {
            return .{ .status = .ok, .body = big_text, .content_type = "text/plain", .headers = &.{.{ "Content-Encoding", "br" }} };
        }
    }.n);
    try testing.expectEqual(@as(usize, 1), count(resp, "content-encoding"));
    try testing.expectEqualStrings("br", header(resp, "content-encoding").?);
    try testing.expectEqualStrings(big_text, resp.body.?);
}

test "gzip: Accept-Encoding is read with its q-values" {
    try testing.expect(acceptsGzip("gzip"));
    try testing.expect(acceptsGzip("gzip, deflate, br"));
    try testing.expect(acceptsGzip("GZIP"));
    try testing.expect(acceptsGzip("deflate, gzip;q=0.5"));
    try testing.expect(acceptsGzip("*"));
    try testing.expect(!acceptsGzip("gzip;q=0"));
    try testing.expect(!acceptsGzip("gzip; q=0.000"));
    try testing.expect(!acceptsGzip("br"));
    try testing.expect(!acceptsGzip("identity"));
    try testing.expect(!acceptsGzip("*;q=0"));
    try testing.expect(!acceptsGzip("*, gzip;q=0"));
    try testing.expect(!acceptsGzip("notgzip"));
}

test "gzip: a client that refused gzip gets the body as it is" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = try ctxWith(arena.allocator(), "gzip;q=0, br");
    const resp = try middleware(&c, struct {
        fn n(_: *Ctx) anyerror!Response {
            return .{ .status = .ok, .body = big_text, .content_type = "text/plain" };
        }
    }.n);
    try testing.expect(header(resp, "content-encoding") == null);
    try testing.expectEqualStrings(big_text, resp.body.?);
}

test "gzip: formats that are already compressed are sent as they are" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    inline for (.{ "image/png", "image/jpeg", "video/mp4", "audio/mpeg", "font/woff2", "application/zip", "application/pdf", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" }) |ct| {
        var c = try ctxWith(arena.allocator(), "gzip");
        const resp = try middleware(&c, struct {
            fn n(_: *Ctx) anyerror!Response {
                return .{ .status = .ok, .body = big_text, .content_type = ct };
            }
        }.n);
        try testing.expect(header(resp, "content-encoding") == null);
    }
    // SVG is text: it is compressed.
    var c = try ctxWith(arena.allocator(), "gzip");
    const svg = try middleware(&c, struct {
        fn n(_: *Ctx) anyerror!Response {
            return .{ .status = .ok, .body = big_text, .content_type = "image/svg+xml" };
        }
    }.n);
    try testing.expectEqualStrings("gzip", header(svg, "content-encoding").?);
}
