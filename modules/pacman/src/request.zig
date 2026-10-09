//! The request itself: `FetchOptions`, the per-method functions (`get`,
//! `post`, ...) and `request`, which sends, enforces the deadline and the
//! size limit, and reads the response to the end.

const std = @import("std");

const Io = std.Io;
const http = std.http;
const HttpClient = @import("std_http/Client.zig");
const Body = @import("body.zig").Body;
const proxy = @import("proxy.zig");
const Headers = @import("headers.zig").Headers;
const Response = @import("response.zig").Response;

/// Default for `FetchOptions.max_response_bytes`: generous enough for a
/// file download, small enough that a misbehaving server can't exhaust the
/// process's memory.
pub const default_max_response_bytes: usize = 64 * 1024 * 1024;

/// The options of a request. Every field has a default: `.{}` is a plain
/// request with no deadline.
pub const FetchOptions = struct {
    /// Set by `post`, `put`, `patch`, `delete`, `head` and by `Client`,
    /// whatever is given here. `get` and `request` send the method given
    /// (GET by default).
    method: http.Method = .GET,
    /// Request headers: `&.{.{ .name = "Authorization", .value = token }}`.
    /// A `Client` ignores this field and sends its own headers.
    headers: []const http.Header = &.{},
    /// The request body. null: none (POST, PUT and PATCH then send an empty
    /// one).
    body: ?Body = null,
    /// Name/value pairs added to the URL as its query string, URL-encoded
    /// (after a `?`, or a `&` when the URL already has a query).
    query: []const [2][]const u8 = &.{},
    /// Values for `:name` placeholders in the URL: `.{ "id", "42" }` turns
    /// `/users/:id` into `/users/42`. The value is inserted as it is (not
    /// URL-encoded); a placeholder without a value stays. Not applied when
    /// `query` is also set.
    params: []const [2][]const u8 = &.{}, // URL path parameters
    /// A URI the caller already parsed, used instead of parsing the URL.
    /// `query` and `params` are then ignored.
    uri: ?std.Uri = null, // pre-built URI (skips std.Uri.parse)
    /// Deadline for the WHOLE request, in milliseconds: connecting, the TLS
    /// handshake, sending, waiting for the response and reading its body.
    /// When it passes, the request is canceled, its connection is closed
    /// (never returned to a pool) and the call fails with `error.Timeout`.
    /// 0 = no deadline: the call waits for as long as the server takes.
    timeout_ms: u32 = 0,
    /// Largest response body accepted, in bytes, counted AFTER
    /// decompression (a small gzip body can inflate to a huge one). A
    /// larger body fails the call with `error.ResponseTooLarge`; nothing
    /// past the limit is kept. Raise it for a known-large download; use
    /// `std.math.maxInt(usize)` for no limit.
    max_response_bytes: usize = default_max_response_bytes,
    /// Explicit HTTP(S) proxy URL (e.g. "http://user:pass@host:8080").
    /// If omitted, falls back to environment variables (http_proxy/https_proxy/
    /// all_proxy, honoring no_proxy) — if none of those are set either, no
    /// proxy is used (identical behavior to before this option existed).
    proxy_url: ?[]const u8 = null,
};

/// A GET request to `url`, on a connection of its own (opened for this call,
/// closed by `Response.deinit()`). Any HTTP answer comes back as a Response,
/// 4xx and 5xx included. Errors: `error.Timeout` (`timeout_ms` passed),
/// `error.ResponseTooLarge` (`max_response_bytes`), `error.HttpBodyCutShort`
/// (the body stopped early), or the error of the connection or of parsing
/// `url`. Redirects are not followed. The response is allocated from
/// `allocator` and owns its memory: call `deinit()`.
pub fn get(io: Io, allocator: std.mem.Allocator, url: []const u8, opts: FetchOptions) !Response {
    return request(io, allocator, url, opts, null);
}

/// A POST request to `url` with `opts.body`. See `get`.
pub fn post(io: Io, allocator: std.mem.Allocator, url: []const u8, opts: FetchOptions) !Response {
    var opts_copy = opts;
    opts_copy.method = .POST;
    return request(io, allocator, url, opts_copy, null);
}

/// A PUT request to `url` with `opts.body`. See `get`.
pub fn put(io: Io, allocator: std.mem.Allocator, url: []const u8, opts: FetchOptions) !Response {
    var opts_copy = opts;
    opts_copy.method = .PUT;
    return request(io, allocator, url, opts_copy, null);
}

/// A PATCH request to `url` with `opts.body`. See `get`.
pub fn patch(io: Io, allocator: std.mem.Allocator, url: []const u8, opts: FetchOptions) !Response {
    var opts_copy = opts;
    opts_copy.method = .PATCH;
    return request(io, allocator, url, opts_copy, null);
}

/// A DELETE request to `url`. See `get`.
pub fn delete(io: Io, allocator: std.mem.Allocator, url: []const u8, opts: FetchOptions) !Response {
    var opts_copy = opts;
    opts_copy.method = .DELETE;
    return request(io, allocator, url, opts_copy, null);
}

/// A HEAD request to `url`: status and headers, an empty body. See `get`.
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

/// How many times a request is sent again because its pooled connection
/// turned out to be dead. One is enough when nothing else is going on (the
/// retry drops the other idle connections first); the second covers a
/// connection another request returned to the pool in between.
const max_stale_retries = 2;

/// Sends the request and waits for the response head.
fn sendRequest(req: *HttpClient.Request, payload_opt: ?[]const u8, method: http.Method) !HttpClient.Response {
    if (payload_opt) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        // Need to cast to mutable bytes
        const mutable_payload = @constCast(payload);
        try req.sendBodyComplete(mutable_payload);
    } else {
        // For methods that require a body (POST, PUT, PATCH), send empty body with Content-Length: 0
        switch (method) {
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
    return req.receiveHead(&.{});
}

/// True when `err` means the request met a connection the server had
/// already closed, and sending it again is safe.
///
/// Servers close idle keep-alive connections without telling the client;
/// the next request on one fails before a byte of response arrives. That
/// only happens to a connection taken from the pool, so a new connection
/// that fails is a real failure. And only methods that may be repeated are
/// sent again (RFC 9110, 9.2.2): the server may have received a POST before
/// the connection died, and whether to repeat it is the caller's call.
fn staleConnection(req: *HttpClient.Request, method: http.Method, err: anyerror) bool {
    const connection = req.connection orelse return false;
    if (!connection.reused) return false;
    switch (method) {
        .GET, .HEAD, .PUT, .DELETE, .OPTIONS, .TRACE => {},
        else => return false,
    }
    return switch (err) {
        error.HttpConnectionClosing => true,
        // A reset or a broken pipe. Not a cancelation (a timeout cancels
        // the request): that one must end it.
        error.ReadFailed => (connection.getReadError() orelse return true) != error.Canceled,
        error.WriteFailed => (connection.stream_writer.err orelse return true) != error.Canceled,
        else => false,
    };
}

/// The other idle connections to the same place sat unused at least as
/// long as the dead one: close them, so the retry opens a new one.
fn dropIdleLike(http_client: *HttpClient, io: Io, connection: *HttpClient.Connection) void {
    http_client.connection_pool.dropIdle(io, .{
        .host = connection.host(),
        .port = connection.port,
        .protocol = connection.protocol,
    });
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

/// The outcome of the race between a request and its deadline.
const Race = union(enum) {
    response: anyerror!Response,
    deadline: Io.Cancelable!void,
};

fn discard(outcome: Race) void {
    switch (outcome) {
        .response => |r| if (r) |res| {
            var owned = res;
            owned.deinit();
        } else |_| {},
        .deadline => {},
    }
}

/// Sends one request with the method in `opts.method`: what `get`, `post`
/// and `Client` call.
///
/// `existing_client`, when non-null, is a persistent HttpClient owned by a
/// `pacman.Client` — reused across many requests instead of created fresh
/// here. This function never destroys it; ownership stays with the caller
/// (see Response.owns_http_client).
pub fn request(io: Io, allocator: std.mem.Allocator, url: []const u8, opts: FetchOptions, existing_client: ?*HttpClient) !Response {
    if (opts.timeout_ms == 0) return requestNoDeadline(io, allocator, url, opts, existing_client);

    // The request runs as a task of its own, raced against a clock. Whoever
    // loses is canceled: cancelation interrupts a network read that is
    // blocked (see local_test.zig, "phase 0"), and the request's own error
    // paths close the connection.
    var buf: [2]Race = undefined;
    var select: Io.Select(Race) = .init(io, &buf);
    // Nothing may be left running, whichever way this function returns. A
    // request that finished in the meantime owns memory and a socket.
    defer while (select.cancel()) |leftover| discard(leftover);

    try select.concurrent(.response, requestNoDeadline, .{ io, allocator, url, opts, existing_client });
    try select.concurrent(.deadline, Io.sleep, .{ io, Io.Duration.fromMilliseconds(opts.timeout_ms), Io.Clock.awake });

    return switch (try select.await()) {
        .response => |r| r,
        .deadline => error.Timeout,
    };
}

fn requestNoDeadline(io: Io, allocator: std.mem.Allocator, url: []const u8, opts: FetchOptions, existing_client: ?*HttpClient) anyerror!Response {
    var arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }

    const aa = arena.allocator();

    var owns_http_client = false;
    const http_client: *HttpClient = existing_client orelse blk: {
        const c = try aa.create(HttpClient);
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

    var req: HttpClient.Request = undefined;
    var response: HttpClient.Response = undefined;
    var stale_retries: u8 = 0;
    while (true) {
        // If a SOCKS5(h) proxy applies, we pre-establish the tunnel ourselves and
        // hand the resulting Connection to http_client.request() below — SOCKS5
        // isn't HTTP, so HttpClient can't dial it on its own the way it does
        // for HTTP(S) proxies via .http_proxy/.https_proxy. Otherwise (HTTP(S)
        // proxy or none), fall back to the existing configure() path, which lets
        // http_client.request() dial (and proxy) the connection itself.
        var explicit_connection: ?*HttpClient.Connection = null;
        {
            var host_buf: [Io.net.HostName.max_len]u8 = undefined;
            if (Io.net.HostName.fromUri(uri, &host_buf)) |host_name| {
                const target_protocol = HttpClient.Protocol.fromUri(uri) orelse .plain;
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
        req = try http_client.request(opts.method, uri, .{
            .extra_headers = extra_headers,
            .connection = explicit_connection,
        });

        if (sendRequest(&req, payload_opt, opts.method)) |received| {
            response = received;
            break;
        } else |err| {
            // A request that fails or is canceled midway closes its
            // connection: it is not left open (it used to be, until the
            // process ended) and a persistent client never reuses it.
            // Marked as closing BEFORE deinit() on purpose — otherwise
            // deinit() tries to read the rest of the response to keep the
            // connection reusable, and that read can block for as long as
            // the server likes.
            const again = stale_retries < max_stale_retries and staleConnection(&req, opts.method, err);
            if (again) dropIdleLike(http_client, io, req.connection.?);
            if (req.connection) |connection| connection.closing = true;
            req.deinit();
            if (!again) return err;
            stale_retries += 1;
        }
    }
    errdefer {
        if (req.connection) |connection| connection.closing = true;
        req.deinit();
    }

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

    // A declared length over the limit is refused before reading a byte of
    // it. (Only when not compressed: otherwise the declared length is of the
    // compressed bytes, and the limit is checked as the body inflates.)
    if (response.head.content_length) |declared| {
        if (response.head.content_encoding == .identity and declared > opts.max_response_bytes) {
            return error.ResponseTooLarge;
        }
    }

    // Read the response body
    var body_list = std.ArrayList(u8).initCapacity(aa, 4096) catch unreachable;

    var transfer_buffer: [4096]u8 = undefined;
    var decompress: http.Decompress = undefined;
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    // The body as framed on the wire (Content-Length / chunked), and on top
    // of it the decompressing reader the loop below reads from.
    // A response without a body (HEAD) still carries the headers of the
    // body it would have had: there is nothing to inflate.
    const content_encoding: http.ContentEncoding = if (opts.method.responseHasBody()) response.head.content_encoding else .identity;
    // Without a body, response.reader() hands out a shared constant reader
    // that must not be read from (reading writes to it): use an empty one
    // of our own.
    var no_body: std.Io.Reader = .fixed(&.{});
    const transfer_reader = if (opts.method.responseHasBody()) response.reader(&transfer_buffer) else &no_body;
    const reader = decompress.init(transfer_reader, &decompress_buffer, content_encoding);

    // Read body in chunks
    while (true) {
        var chunk: [4096]u8 = undefined;
        // A read that fails in the middle of the body is an error, not the
        // end of the body: returning what arrived so far would hand the
        // caller a truncated response with the original (successful) status.
        const bytes_read = reader.*.readSliceShort(&chunk) catch return error.HttpBodyCutShort;
        if (bytes_read == 0) break;
        // `reader` is the decompressing one: this counts inflated bytes.
        if (bytes_read > opts.max_response_bytes - body_list.items.len) return error.ResponseTooLarge;
        try body_list.appendSlice(aa, chunk[0..bytes_read]);
    }

    // A server that promised Content-Length bytes and hung up early ends the
    // stream without a read error. Only comparable when the body was not
    // compressed (the length is of the bytes on the wire) and the response
    // has a body at all.
    if (response.head.content_length) |promised| {
        const has_body = opts.method != .HEAD and response.head.status != .no_content and response.head.status != .not_modified;
        if (has_body and response.head.content_encoding == .identity and body_list.items.len < promised) {
            return error.HttpBodyCutShort;
        }
    }

    const body_text = try body_list.toOwnedSlice(aa);

    // A compressed stream can end before the framing does (the last chunk
    // of a chunked body, bytes after a gzip trailer). Read to the end of the
    // framing: otherwise the connection is not at a message boundary and
    // deinit() closes it instead of returning it to the pool.
    if (content_encoding != .identity) _ = transfer_reader.discardRemaining() catch {};

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
