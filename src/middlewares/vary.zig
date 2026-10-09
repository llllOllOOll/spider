//! spider.varyHtmx: `Vary: HX-Request` on HTML responses, so a cache (service
//! worker, CDN) never serves an htmx fragment for a full page or the reverse.

const std = @import("std");
const ctx_mod = @import("../core/context.zig");
const Ctx = ctx_mod.Ctx;
const Response = ctx_mod.Response;
const NextFn = ctx_mod.NextFn;

/// A middleware that adds `Vary: HX-Request` to every response whose content
/// type is `text/html`, so a cache keeps the htmx fragment and the full page
/// of one URL apart. Other responses pass unchanged.
///
/// ```zig
/// server.use(spider.varyHtmx)
/// ```
pub fn varyHtmx(c: *Ctx, next: NextFn) anyerror!Response {
    var resp = try next(c);
    if (std.mem.indexOf(u8, resp.content_type, "text/html") != null) {
        const hdrs = try c.arena.alloc([2][]const u8, resp.headers.len + 1);
        @memcpy(hdrs[0..resp.headers.len], resp.headers);
        hdrs[resp.headers.len] = .{ "Vary", "HX-Request" };
        resp.headers = hdrs;
    }
    return resp;
}
