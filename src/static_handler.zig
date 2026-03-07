const std = @import("std");
const web = @import("web.zig");

pub fn serve(alc: std.mem.Allocator, req: *web.Request) !web.Response {
    const path = req.path;

    const full_path = try std.fs.path.join(alc, &.{ ".", path });
    defer alc.free(full_path);

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const content = std.Io.Dir.cwd().readFileAlloc(
        io,
        full_path,
        alc,
        .limited(10 * 1024 * 1024),
    ) catch {
        return web.Response.text(alc, "Not Found");
    };

    var res = web.Response.init();
    res.allocator = alc;
    res.body = content;
    res.body_allocated = true;
    try res.headers.set(alc, "content-type", mimeType(path));
    return res;
}

fn mimeType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript";
    if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
    if (std.mem.endsWith(u8, path, ".html")) return "text/html";
    if (std.mem.endsWith(u8, path, ".woff2")) return "font/woff2";
    return "application/octet-stream";
}
