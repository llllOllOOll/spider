//! `Client`: many requests to one server over connections that stay open.
//! The `async*` functions at the end are the same calls as plain functions.

const std = @import("std");

const Io = std.Io;
const http = std.http;
const HttpClient = @import("std_http/Client.zig");
const Response = @import("response.zig").Response;
const FetchOptions = @import("request.zig").FetchOptions;
const doRequest = @import("request.zig").request;
const proxy = @import("proxy.zig");

/// A client bound to one base URL, with a pool of kept-alive connections.
/// Create it once and share it; requests may run through it concurrently.
///
/// ```zig
/// var client = try spider.http_client.Client.init(io, allocator, .{
///     .base_url = "https://api.example.com",
///     .headers = &.{.{ .name = "Authorization", .value = bearer }},
/// });
/// defer client.deinit();
///
/// var res = try client.get("/users", .{ .timeout_ms = 3000 });
/// defer res.deinit();
/// ```
pub const Client = struct {
    // internal: the Io every request of this client runs on
    io: Io,
    // internal: what responses and connections are allocated with
    allocator: std.mem.Allocator,
    /// The `base_url` given to `init`.
    base_url: []const u8,
    /// The `headers` given to `init`.
    headers: []const std.http.Header,
    /// The `proxy_url` given to `init`.
    proxy_url: ?[]const u8,
    /// Persistent — created once here, reused (with its connection pool)
    /// across every .get()/.post()/etc made through this Client. Closed by
    /// Client.deinit(), not by individual Response.deinit() calls (see
    /// Response.owns_http_client).
    http_client: HttpClient,
    /// Owns the proxy settings `http_client` points at.
    proxy_arena: std.heap.ArenaAllocator,

    /// A client for `opts.base_url`. No connection is opened yet. Fails when
    /// `proxy_url` is not a valid URL, or out of memory. The strings and the
    /// header list of `opts` are not copied: they must stay valid as long as
    /// the Client.
    pub fn init(io: Io, allocator: std.mem.Allocator, opts: struct {
        /// Scheme and host, and a path prefix if any. Each request's `path`
        /// is appended to it as it is, so write one slash between them.
        base_url: []const u8,
        /// Sent with every request (an API key, a user agent). Default: none.
        headers: []const std.http.Header = &.{},
        /// The proxy for every request of this client, fixed here. null: the
        /// proxy environment variables apply (see `FetchOptions.proxy_url`).
        proxy_url: ?[]const u8 = null,
        /// A connection left unused for longer than this is closed rather
        /// than reused. Servers drop idle connections on their side
        /// (Cloudflare within minutes); 30 s stays under the usual limits.
        /// 0: no limit.
        idle_timeout_ms: u32 = 30_000,
        /// false: every request opens its own connection and closes it.
        /// Slower (a handshake per request), never meets a stale one.
        keep_alive: bool = true,
    }) !Client {
        var http_client: HttpClient = .{ .allocator = allocator, .io = io };
        if (opts.idle_timeout_ms > 0) http_client.connection_pool.max_idle = .fromMilliseconds(opts.idle_timeout_ms);
        if (!opts.keep_alive) http_client.connection_pool.free_size = 0;

        // Fixed once, here — not per-call. HttpClient.http_proxy/https_proxy
        // are client-level fields; mutating them on every request would race
        // with other in-flight requests through this same persistent client.
        // See call()'s ProxyMismatch check below.
        var host_buf: [Io.net.HostName.max_len]u8 = undefined;
        const target_host: []const u8 = blk: {
            const uri = std.Uri.parse(opts.base_url) catch break :blk "";
            const host_name = Io.net.HostName.fromUri(uri, &host_buf) catch break :blk "";
            break :blk host_name.bytes;
        };
        var proxy_arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer proxy_arena.deinit();
        try proxy.configure(proxy_arena.allocator(), &http_client, opts.proxy_url, target_host);

        return .{
            .io = io,
            .allocator = allocator,
            .base_url = opts.base_url,
            .headers = opts.headers,
            .proxy_url = opts.proxy_url,
            .http_client = http_client,
            .proxy_arena = proxy_arena,
        };
    }

    /// Closes the connection pool. Call once, when done with this Client.
    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
        self.proxy_arena.deinit();
    }

    /// A GET to `base_url ++ path`. Like the standalone `get`, but the
    /// connection is reused, and the request carries the headers given to
    /// `init` followed by `opts.headers` (one of those with the name of a
    /// client header replaces it, for this request). `error.ProxyMismatch`
    /// when `opts.proxy_url` is set to something other than the client's
    /// proxy.
    pub fn get(self: *Client, path: []const u8, opts: FetchOptions) !Response {
        return self.call(.GET, path, opts);
    }

    /// A POST to `base_url ++ path` with `opts.body`. See `get`.
    pub fn post(self: *Client, path: []const u8, opts: FetchOptions) !Response {
        return self.call(.POST, path, opts);
    }

    /// A PUT to `base_url ++ path`. See `get`.
    pub fn put(self: *Client, path: []const u8, opts: FetchOptions) !Response {
        return self.call(.PUT, path, opts);
    }

    /// A PATCH to `base_url ++ path`. See `get`.
    pub fn patch(self: *Client, path: []const u8, opts: FetchOptions) !Response {
        return self.call(.PATCH, path, opts);
    }

    /// A DELETE to `base_url ++ path`. See `get`.
    pub fn delete(self: *Client, path: []const u8, opts: FetchOptions) !Response {
        return self.call(.DELETE, path, opts);
    }

    /// `opts.proxy_url`, if set, must match the proxy fixed at `init()` time.
    /// This Client's HttpClient is a persistent, shared connection pool —
    /// http_proxy/https_proxy can't be safely reconfigured per call (races
    /// with concurrent in-flight requests through the same client, and would
    /// leak stale proxy config across calls). A differing value is treated
    /// as a usage error, not silently ignored. For per-call proxy control,
    /// use the standalone functions (pacman.get, etc.) instead.
    fn call(self: *Client, method: http.Method, path: []const u8, opts: FetchOptions) !Response {
        if (opts.proxy_url) |url| {
            const matches = if (self.proxy_url) |fixed| std.mem.eql(u8, url, fixed) else false;
            if (!matches) return error.ProxyMismatch;
        }

        const full_url = try std.mem.concat(self.allocator, u8, &.{ self.base_url, path });
        defer self.allocator.free(full_url);

        // The client's headers, then the request's. A request header with
        // the name of one of the client's replaces it for this request.
        const headers = try self.allocator.alloc(http.Header, self.headers.len + opts.headers.len);
        defer self.allocator.free(headers);
        var n: usize = 0;
        for (self.headers) |own| {
            const replaced = for (opts.headers) |given| {
                if (std.ascii.eqlIgnoreCase(given.name, own.name)) break true;
            } else false;
            if (replaced) continue;
            headers[n] = own;
            n += 1;
        }
        @memcpy(headers[n..][0..opts.headers.len], opts.headers);
        n += opts.headers.len;

        var call_opts = opts;
        call_opts.method = method;
        call_opts.headers = headers[0..n];
        call_opts.proxy_url = self.proxy_url;

        return doRequest(self.io, self.allocator, full_url, call_opts, &self.http_client);
    }
};

/// `client.get(path, opts)` as a plain function, to hand to `io.async`.
/// It does not start anything by itself.
pub fn asyncGet(client: *Client, path: []const u8, opts: FetchOptions) !Response {
    return client.get(path, opts);
}

/// `client.post(path, opts)` as a plain function, for `io.async`.
pub fn asyncPost(client: *Client, path: []const u8, opts: FetchOptions) !Response {
    return client.post(path, opts);
}

/// `client.put(path, opts)` as a plain function, for `io.async`.
pub fn asyncPut(client: *Client, path: []const u8, opts: FetchOptions) !Response {
    return client.put(path, opts);
}

/// `client.patch(path, opts)` as a plain function, for `io.async`.
pub fn asyncPatch(client: *Client, path: []const u8, opts: FetchOptions) !Response {
    return client.patch(path, opts);
}

/// `client.delete(path, opts)` as a plain function, for `io.async`.
pub fn asyncDelete(client: *Client, path: []const u8, opts: FetchOptions) !Response {
    return client.delete(path, opts);
}
