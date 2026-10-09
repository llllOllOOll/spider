const std = @import("std");

const Io = std.Io;
const http = std.http;
const HttpClient = @import("std_http/Client.zig");
const Response = @import("response.zig").Response;
const FetchOptions = @import("request.zig").FetchOptions;
const doRequest = @import("request.zig").request;
const proxy = @import("proxy.zig");

pub const Client = struct {
    io: Io,
    allocator: std.mem.Allocator,
    base_url: []const u8,
    headers: []const std.http.Header,
    proxy_url: ?[]const u8,
    /// Persistent — created once here, reused (with its connection pool)
    /// across every .get()/.post()/etc made through this Client. Closed by
    /// Client.deinit(), not by individual Response.deinit() calls (see
    /// Response.owns_http_client).
    http_client: HttpClient,
    /// Owns the proxy settings `http_client` points at.
    proxy_arena: std.heap.ArenaAllocator,

    pub fn init(io: Io, allocator: std.mem.Allocator, opts: struct {
        base_url: []const u8,
        headers: []const std.http.Header = &.{},
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

    pub fn get(self: *Client, path: []const u8, opts: FetchOptions) !Response {
        return self.call(.GET, path, opts);
    }

    pub fn post(self: *Client, path: []const u8, opts: FetchOptions) !Response {
        return self.call(.POST, path, opts);
    }

    pub fn put(self: *Client, path: []const u8, opts: FetchOptions) !Response {
        return self.call(.PUT, path, opts);
    }

    pub fn patch(self: *Client, path: []const u8, opts: FetchOptions) !Response {
        return self.call(.PATCH, path, opts);
    }

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

        var call_opts = opts;
        call_opts.method = method;
        call_opts.headers = self.headers;
        call_opts.proxy_url = self.proxy_url;

        return doRequest(self.io, self.allocator, full_url, call_opts, &self.http_client);
    }
};

pub fn asyncGet(client: *Client, path: []const u8, opts: FetchOptions) !Response {
    return client.get(path, opts);
}

pub fn asyncPost(client: *Client, path: []const u8, opts: FetchOptions) !Response {
    return client.post(path, opts);
}

pub fn asyncPut(client: *Client, path: []const u8, opts: FetchOptions) !Response {
    return client.put(path, opts);
}

pub fn asyncPatch(client: *Client, path: []const u8, opts: FetchOptions) !Response {
    return client.patch(path, opts);
}

pub fn asyncDelete(client: *Client, path: []const u8, opts: FetchOptions) !Response {
    return client.delete(path, opts);
}
