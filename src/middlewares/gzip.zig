const std = @import("std");
const Ctx = @import("../core/context.zig").Ctx;
const NextFn = @import("../core/context.zig").NextFn;
const Response = @import("../core/context.zig").Response;
const dev_reload = @import("../modules/dev_reload.zig");

const MIN_COMPRESS_BYTES: usize = 1024;

/// Case-insensitive check whether the request includes Accept-Encoding: gzip.
fn clientAcceptsGzip(headers: std.StringHashMapUnmanaged([]const u8)) bool {
    var iter = headers.iterator();
    while (iter.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "accept-encoding")) {
            if (std.mem.indexOf(u8, entry.value_ptr.*, "gzip") != null) {
                return true;
            }
        }
    }
    return false;
}

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
