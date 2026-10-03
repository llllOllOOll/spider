const std = @import("std");

const Io = std.Io;
const http = std.http;
const Body = @import("body.zig").Body;
const proxy = @import("proxy.zig");
const Headers = @import("headers.zig").Headers;
const Response = @import("response.zig").Response;

pub const FetchOptions = struct {
    method: http.Method = .GET,
    headers: []const http.Header = &.{},
    body: ?Body = null,
    query: []const [2][]const u8 = &.{},
    params: []const [2][]const u8 = &.{}, // URL path parameters
    uri: ?std.Uri = null, // pre-built URI (skips std.Uri.parse)
    timeout_ms: u32 = 0, // 0 = no timeout
    /// Explicit HTTP(S) proxy URL (e.g. "http://user:pass@host:8080").
    /// If omitted, falls back to environment variables (http_proxy/https_proxy/
    /// all_proxy, honoring no_proxy) — if none of those are set either, no
    /// proxy is used (identical behavior to before this option existed).
    proxy_url: ?[]const u8 = null,
};

pub fn get(io: Io, allocator: std.mem.Allocator, url: []const u8, opts: FetchOptions) !Response {
    return request(io, allocator, url, opts, null);
}

pub fn post(io: Io, allocator: std.mem.Allocator, url: []const u8, opts: FetchOptions) !Response {
    var opts_copy = opts;
    opts_copy.method = .POST;
    return request(io, allocator, url, opts_copy, null);
}

pub fn put(io: Io, allocator: std.mem.Allocator, url: []const u8, opts: FetchOptions) !Response {
    var opts_copy = opts;
    opts_copy.method = .PUT;
    return request(io, allocator, url, opts_copy, null);
}

pub fn patch(io: Io, allocator: std.mem.Allocator, url: []const u8, opts: FetchOptions) !Response {
    var opts_copy = opts;
    opts_copy.method = .PATCH;
    return request(io, allocator, url, opts_copy, null);
}

pub fn delete(io: Io, allocator: std.mem.Allocator, url: []const u8, opts: FetchOptions) !Response {
    var opts_copy = opts;
    opts_copy.method = .DELETE;
    return request(io, allocator, url, opts_copy, null);
}

pub fn head(io: Io, allocator: std.mem.Allocator, url: []const u8, opts: FetchOptions) !Response {
    var opts_copy = opts;
    opts_copy.method = .HEAD;
    return request(io, allocator, url, opts_copy, null);
}

fn encodeQueryComponentLen(s: []const u8) usize {
    var escape_count: usize = 0;
    for (s) |c| {
        if (shouldEscape(c)) {
            escape_count += 1;
        }
    }
    return s.len + 2 * escape_count;
}

const UPPER_HEX = "0123456789ABCDEF";

fn encodeQueryComponent(s: []const u8, writer: anytype) !void {
    for (s) |c| {
        if (shouldEscape(c)) {
            try writer.writeByte('%');
            try writer.writeByte(UPPER_HEX[c >> 4]);
            try writer.writeByte(UPPER_HEX[c & 15]);
        } else {
            try writer.writeByte(c);
        }
    }
}

fn shouldEscape(c: u8) bool {
    // fast path for common cases
    if (std.ascii.isAlphanumeric(c)) {
        return false;
    }
    return c != '-' and c != '_' and c != '.' and c != '~';
}

fn hasContentType(headers: []const http.Header) bool {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-type")) return true;
    }
    return false;
}

/// `existing_client`, when non-null, is a persistent http.Client owned by a
/// `pacman.Client` — reused across many requests instead of created fresh
/// here. This function never destroys it; ownership stays with the caller
/// (see Response.owns_http_client).
pub fn request(io: Io, allocator: std.mem.Allocator, url: []const u8, opts: FetchOptions, existing_client: ?*http.Client) !Response {
    var arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }

    const aa = arena.allocator();

    var owns_http_client = false;
    const http_client: *http.Client = existing_client orelse blk: {
        const c = try aa.create(http.Client);
        c.* = .{ .allocator = aa, .io = io };
        owns_http_client = true;
        break :blk c;
    };

    var payload_opt: ?[]const u8 = null;
    var extra_headers = opts.headers;

    if (opts.body) |b| {
        switch (b) {
            .raw => |raw| {
                payload_opt = raw;
                if (!hasContentType(opts.headers)) {
                    extra_headers = try std.mem.concat(aa, http.Header, &.{
                        opts.headers,
                        &.{.{ .name = "Content-Type", .value = "application/octet-stream" }},
                    });
                }
            },
            .json => |json_data| {
                // Copy JSON data into arena for automatic cleanup
                const owned = try aa.dupe(u8, json_data);
                payload_opt = owned;
                if (!hasContentType(opts.headers)) {
                    extra_headers = try std.mem.concat(aa, http.Header, &.{
                        opts.headers,
                        &.{.{ .name = "Content-Type", .value = "application/json" }},
                    });
                }
            },
            .form => |form| {
                // URL-encode form data
                var form_buf = std.ArrayList(u8).initCapacity(aa, 100) catch unreachable;

                for (form, 0..) |param, i| {
                    if (i > 0) {
                        try form_buf.append(aa, '&');
                    }

                    // Encode key
                    for (param[0]) |c| {
                        if (shouldEscape(c)) {
                            try form_buf.appendSlice(aa, "%");
                            try form_buf.append(aa, UPPER_HEX[c >> 4]);
                            try form_buf.append(aa, UPPER_HEX[c & 15]);
                        } else {
                            try form_buf.append(aa, c);
                        }
                    }

                    try form_buf.append(aa, '=');

                    // Encode value
                    for (param[1]) |c| {
                        if (shouldEscape(c)) {
                            try form_buf.appendSlice(aa, "%");
                            try form_buf.append(aa, UPPER_HEX[c >> 4]);
                            try form_buf.append(aa, UPPER_HEX[c & 15]);
                        } else {
                            try form_buf.append(aa, c);
                        }
                    }
                }

                payload_opt = try form_buf.toOwnedSlice(aa);
                if (!hasContentType(opts.headers)) {
                    extra_headers = try std.mem.concat(aa, http.Header, &.{
                        opts.headers,
                        &.{.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }},
                    });
                }
            },
        }
    }

    // Handle URL path parameters
    var final_url: []const u8 = url;
    if (opts.params.len > 0) {
        var param_buf = std.ArrayList(u8).initCapacity(aa, url.len) catch unreachable;

        var i: usize = 0;
        while (i < url.len) {
            if (i + 1 < url.len and url[i] == ':' and std.ascii.isAlphabetic(url[i + 1])) {
                // Found a parameter
                const param_start = i + 1;
                var param_end = param_start;
                while (param_end < url.len and (std.ascii.isAlphanumeric(url[param_end]) or url[param_end] == '_')) {
                    param_end += 1;
                }

                const param_name = url[param_start..param_end];
                var found = false;

                // Look for matching parameter value
                for (opts.params) |param| {
                    if (std.mem.eql(u8, param[0], param_name)) {
                        try param_buf.appendSlice(aa, param[1]);
                        found = true;
                        break;
                    }
                }

                if (!found) {
                    // Parameter not found, keep original
                    try param_buf.appendSlice(aa, url[i..param_end]);
                }

                i = param_end;
            } else {
                // Regular character
                try param_buf.append(aa, url[i]);
                i += 1;
            }
        }

        final_url = try param_buf.toOwnedSlice(aa);
    }

    // Handle query parameters
    if (opts.query.len > 0) {
        var query_buf = std.ArrayList(u8).initCapacity(aa, url.len + opts.query.len + 10) catch unreachable;

        try query_buf.appendSlice(aa, url);

        // Check if URL already has query parameters
        const has_query = std.mem.indexOfScalar(u8, url, '?') != null;
        if (has_query) {
            // URL already has query parameters, add with & separator
            try query_buf.append(aa, '&');
        } else {
            // URL has no query parameters, start with ?
            try query_buf.append(aa, '?');
        }

        // Add each query parameter
        for (opts.query, 0..) |param, i| {
            if (i > 0) {
                try query_buf.append(aa, '&');
            }

            const key = param[0];
            const value = param[1];

            // Encode key
            for (key) |c| {
                if (shouldEscape(c)) {
                    try query_buf.appendSlice(aa, "%");
                    try query_buf.append(aa, UPPER_HEX[c >> 4]);
                    try query_buf.append(aa, UPPER_HEX[c & 15]);
                } else {
                    try query_buf.append(aa, c);
                }
            }
            try query_buf.append(aa, '=');
            // Encode value
            for (value) |c| {
                if (shouldEscape(c)) {
                    try query_buf.appendSlice(aa, "%");
                    try query_buf.append(aa, UPPER_HEX[c >> 4]);
                    try query_buf.append(aa, UPPER_HEX[c & 15]);
                } else {
                    try query_buf.append(aa, c);
                }
            }
        }

        final_url = try query_buf.toOwnedSlice(aa);
    }

    const uri = if (opts.uri) |u| u else try std.Uri.parse(final_url);

    // If a SOCKS5(h) proxy applies, we pre-establish the tunnel ourselves and
    // hand the resulting Connection to http_client.request() below — SOCKS5
    // isn't HTTP, so http.Client can't dial it on its own the way it does
    // for HTTP(S) proxies via .http_proxy/.https_proxy. Otherwise (HTTP(S)
    // proxy or none), fall back to the existing configure() path, which lets
    // http_client.request() dial (and proxy) the connection itself.
    var explicit_connection: ?*http.Client.Connection = null;
    {
        var host_buf: [Io.net.HostName.max_len]u8 = undefined;
        if (uri.getHost(&host_buf)) |host_name| {
            const target_protocol = http.Client.Protocol.fromUri(uri) orelse .plain;
            const target_port: u16 = uri.port orelse switch (target_protocol) {
                .plain => 80,
                .tls => 443,
            };
            explicit_connection = try proxy.connectSocks5(io, aa, http_client, opts.proxy_url, host_name.bytes, target_port, target_protocol);
            // http_client.http_proxy/https_proxy are client-level fields,
            // not per-request. For an owned (single-request) client it's
            // safe to set them here. For a persistent, shared Client, they
            // were already fixed once in Client.init() — reconfiguring per
            // call would race with other in-flight requests through the
            // same client (Client.call() enforces this by rejecting a
            // differing opts.proxy_url with error.ProxyMismatch before we
            // ever get here).
            if (explicit_connection == null and owns_http_client) {
                try proxy.configure(aa, http_client, opts.proxy_url, host_name.bytes);
            }
        } else |_| {}
    }

    // Create a Request to have access to response headers
    var req = try http_client.request(opts.method, uri, .{
        .extra_headers = extra_headers,
        .connection = explicit_connection,
    });

    // Send the request
    if (payload_opt) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        // Need to cast to mutable bytes
        const mutable_payload = @constCast(payload);
        try req.sendBodyComplete(mutable_payload);
    } else {
        // For methods that require a body (POST, PUT, PATCH), send empty body with Content-Length: 0
        switch (opts.method) {
            .POST, .PUT, .PATCH => {
                req.transfer_encoding = .{ .content_length = 0 };
                try req.sendBodyComplete(&.{});
            },
            else => {
                try req.sendBodiless();
            },
        }
    }

    // Wait for response headers
    var response = try req.receiveHead(&.{});

    // Extract response headers from raw header bytes BEFORE reading body
    var response_headers: []http.Header = &.{};
    const header_bytes = response.head.bytes;

    // Parse headers from raw HTTP response
    var header_list = std.ArrayList(http.Header).initCapacity(aa, 10) catch unreachable;
    var lines = std.mem.splitSequence(u8, header_bytes, "\r\n");

    // Skip the first line (status line)
    _ = lines.next();

    // Parse each header line
    while (lines.next()) |line| {
        if (line.len == 0) break; // Empty line indicates end of headers

        // Skip continuation lines (starting with space/tab)
        if (line[0] == ' ' or line[0] == '\t') continue;

        // Split header name and value
        if (std.mem.indexOfScalar(u8, line, ':')) |colon_index| {
            const name = line[0..colon_index];
            const value_start = colon_index + 1;
            const value = std.mem.trim(u8, line[value_start..], " \t");

            if (name.len > 0 and value.len > 0) {
                try header_list.append(aa, .{
                    .name = try aa.dupe(u8, name),
                    .value = try aa.dupe(u8, value),
                });
            }
        }
    }

    response_headers = try header_list.toOwnedSlice(aa);

    // Read the response body
    var body_list = std.ArrayList(u8).initCapacity(aa, 4096) catch unreachable;

    var transfer_buffer: [4096]u8 = undefined;
    var decompress: http.Decompress = undefined;
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);

    // Read body in chunks
    while (true) {
        var chunk: [4096]u8 = undefined;
        const bytes_read = reader.*.readSliceShort(&chunk) catch break;
        if (bytes_read == 0) break;
        try body_list.appendSlice(aa, chunk[0..bytes_read]);
    }

    const body_text = try body_list.toOwnedSlice(aa);

    // Deinit the request
    req.deinit();

    return .{
        .status = response.head.status,
        .headers = .{ .items = response_headers },
        .arena = arena,
        .body_text = body_text,
        .http_client = http_client,
        .owns_http_client = owns_http_client,
    };
}
