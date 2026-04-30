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

pub fn serve(
    io: std.Io,
    arena: std.mem.Allocator,
    config: StaticConfig,
    request_path: []const u8,
) !?Response {
    if (!std.mem.startsWith(u8, request_path, config.prefix)) return null;

    const after_prefix = request_path[config.prefix.len..];

    if (std.mem.indexOf(u8, after_prefix, "..") != null) return null;

    const relative = if (after_prefix.len > 0 and after_prefix[0] == '/')
        after_prefix[1..]
    else
        after_prefix;

    return serveFile(io, arena, config.dir, relative);
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
