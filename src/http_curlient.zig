const std = @import("std");
const curl = @import("curl");

pub const HttpError = error{ RequestFailed, BadStatus };

pub const Header = std.http.Header;

var initialized: bool = false;

fn ensureInit() !void {
    if (!initialized) {
        try curl.globalInit();
        initialized = true;
    }
}

pub fn get(
    alloc: std.mem.Allocator,
    url: []const u8,
    headers: []const Header,
) ![]u8 {
    try ensureInit();

    var easy = try curl.Easy.init(.{});
    defer easy.deinit();
    try easy.setInsecure(true);
    // try easy.setVerbose(true);

    const url_z = try alloc.dupeZ(u8, url);
    defer alloc.free(url_z);

    var curl_list = std.ArrayList([:0]const u8).empty;
    errdefer curl_list.deinit(alloc);
    for (headers) |h| {
        const header = try std.fmt.allocPrint(alloc, "{s}: {s}", .{ h.name, h.value });
        defer alloc.free(header);
        const header_z = try alloc.dupeZ(u8, header);
        try curl_list.append(alloc, header_z);
    }

    var writer = std.Io.Writer.Allocating.init(alloc);
    errdefer writer.deinit();

    const resp = try easy.fetch(url_z, .{
        .headers = curl_list.items,
        .writer = &writer.writer,
    });

    if (resp.status_code != 200) {
        return HttpError.BadStatus;
    }

    const result = writer.writer.buffered();
    return try alloc.dupe(u8, result);
}

pub fn post(
    alloc: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    content_type: []const u8,
) ![]u8 {
    try ensureInit();

    var easy = try curl.Easy.init(.{});
    defer easy.deinit();
    try easy.setInsecure(true);
    // try easy.setVerbose(true);

    const url_z = try alloc.dupeZ(u8, url);
    defer alloc.free(url_z);

    const content_type_header = try std.fmt.allocPrint(alloc, "Content-Type: {s}", .{content_type});
    defer alloc.free(content_type_header);
    const content_type_z = try alloc.dupeZ(u8, content_type_header);
    defer alloc.free(content_type_z);

    var writer = std.Io.Writer.Allocating.init(alloc);
    errdefer writer.deinit();

    const resp = try easy.fetch(url_z, .{
        .method = .POST,
        .body = body,
        .headers = &.{content_type_z},
        .writer = &writer.writer,
    });

    if (resp.status_code != 200) {
        return HttpError.BadStatus;
    }

    const result = writer.writer.buffered();
    return try alloc.dupe(u8, result);
}
