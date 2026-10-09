//! The answer to a request: status, headers and the whole body in memory.

const std = @import("std");
const http = std.http;
const HttpClient = @import("std_http/Client.zig");

const Headers = @import("headers.zig").Headers;

/// An HTTP answer, read to the end. It owns everything it points to
/// (headers, body, what `json` parses): call `deinit()` once, and copy what
/// must outlive it.
pub const Response = struct {
    /// The status code: `res.status == .ok`, `@intFromEnum(res.status)`.
    status: http.Status,
    /// The response headers: `res.headers.get("content-type")`.
    headers: Headers,
    // internal: owns the memory of this response
    arena: *std.heap.ArenaAllocator,
    /// The body, decompressed. Same as `text()`.
    body_text: []const u8,
    // internal: the connection pool the request went through
    http_client: *HttpClient,
    /// True when `http_client` was created just for this one request (the
    /// standalone get/post/etc path) — this Response then owns its lifetime.
    /// False when `http_client` belongs to a persistent `pacman.Client`
    /// (reused across many requests): in that case `Client.deinit()` closes
    /// it, not this Response — destroying it here would leave every
    /// subsequent request through that Client using a freed HttpClient.
    owns_http_client: bool,

    /// Frees the response. After a single request (`get`, `post`, ...) this
    /// also closes its connection; a `Client`'s connections stay open.
    pub fn deinit(self: *Response) void {
        if (self.owns_http_client) {
            self.http_client.deinit();
            self.arena.allocator().destroy(self.http_client);
        }
        self.arena.deinit();
        self.arena.child_allocator.destroy(self.arena);
    }

    /// The body as bytes. Valid until `deinit()`.
    pub fn text(self: *Response) []const u8 {
        return self.body_text;
    }

    /// The body parsed as JSON into `T`; fields of the body that `T` does not
    /// have are ignored. Fails with the JSON parser's error when the body is
    /// not JSON or does not fit `T`. The result lives in the response's
    /// memory: it is valid until `deinit()` of the response, and its own
    /// `deinit()` is optional.
    ///
    /// ```zig
    /// const parsed = try res.json(struct { access_token: []const u8 = "" });
    /// const token = parsed.value.access_token;
    /// ```
    pub fn json(self: *Response, comptime T: type) !std.json.Parsed(T) {
        const allocator = self.arena.allocator();
        return try std.json.parseFromSlice(T, allocator, self.body_text, .{
            .ignore_unknown_fields = true,
        });
    }
};
