//! Internal: which proxy a request goes through. An explicit URL or the
//! environment (http_proxy, https_proxy, all_proxy, no_proxy); HTTP(S)
//! proxies are set on the client, SOCKS5 ones get a tunnel opened here.

const std = @import("std");
const http = std.http;
const HttpClient = @import("std_http/Client.zig");
const socks5 = @import("socks5.zig");

/// Establishes a SOCKS5(h) tunnel to `target_host:target_port` if a SOCKS5
/// proxy applies — either `explicit_url` with a socks5/socks5h scheme, or
/// (when `explicit_url` is null or empty) the standard `all_proxy`/
/// `ALL_PROXY` environment variables, honoring no_proxy/NO_PROXY the same
/// way `configure()` does. Returns null if no SOCKS5 proxy applies, in which
/// case the caller should fall back to the regular HTTP(S)-proxy-or-direct
/// path (`configure()` + a normal `client.request()`).
///
/// "5h" means the hostname is never resolved locally — it's sent raw to the
/// proxy, which resolves it itself (see socks5.zig).
///
/// On success, the returned Connection is already registered in
/// `client.connection_pool` and ready to pass as `.connection` in
/// `client.request()`.
pub fn connectSocks5(
    io: std.Io,
    allocator: std.mem.Allocator,
    client: *HttpClient,
    explicit_url: ?[]const u8,
    target_host: []const u8,
    target_port: u16,
    target_protocol: HttpClient.Protocol,
) !?*HttpClient.Connection {
    const url = pick: {
        if (explicit_url) |u| {
            if (u.len == 0) break :pick null;
            if (!isSocks5Scheme(u)) return null; // explicit non-SOCKS5 proxy — not our job
            break :pick u;
        }

        if (getEnv("no_proxy") orelse getEnv("NO_PROXY")) |list| {
            if (isBypassed(list, target_host)) break :pick null;
        }
        const value = getEnv("all_proxy") orelse getEnv("ALL_PROXY") orelse break :pick null;
        if (value.len == 0 or !isSocks5Scheme(value)) break :pick null;
        break :pick value;
    } orelse return null;

    const uri = std.Uri.parse(url) catch try std.Uri.parseAfterScheme("socks5", url);
    var proxy_host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const proxy_host = try std.Io.net.HostName.fromUri(uri, &proxy_host_buf);
    const proxy_port: u16 = uri.port orelse 1080;

    var auth: ?socks5.Auth = null;
    if (uri.user != null or uri.password != null) {
        // 256 bytes matches RFC 1929's max username/password length (255 +
        // room for the length-prefix accounting below) — these values only
        // ever feed into the SOCKS5 auth sub-negotiation, which rejects
        // anything longer anyway (see socks5.encodeAuthRequest).
        var user_buf: [256]u8 = undefined;
        var pass_buf: [256]u8 = undefined;
        const user_component: std.Uri.Component = uri.user orelse .empty;
        const pass_component: std.Uri.Component = uri.password orelse .empty;
        const user = try user_component.toRaw(&user_buf);
        const pass = try pass_component.toRaw(&pass_buf);
        auth = .{
            .username = try allocator.dupe(u8, user),
            .password = try allocator.dupe(u8, pass),
        };
    }

    const target_host_name: std.Io.net.HostName = .{ .bytes = target_host };

    if (try client.connection_pool.findConnection(io, .{
        .host = target_host_name,
        .port = target_port,
        .protocol = target_protocol,
    })) |conn| return conn;

    var stream = try proxy_host.connect(io, proxy_port, .{ .mode = .stream });
    errdefer stream.close(io);

    try socks5.connect(io, stream, target_host, target_port, auth);

    return try client.adoptTunneledStream(stream, target_host_name, target_port, target_protocol);
}

fn isSocks5Scheme(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "socks5://") or std.mem.startsWith(u8, url, "socks5h://");
}

/// Configures the HttpClient's proxy, opt-in: if `explicit_url` is given, it
/// takes priority (and ignores no_proxy, same as curl's --proxy). Otherwise
/// falls back to the standard environment variables (http_proxy/https_proxy/
/// all_proxy), honoring no_proxy/NO_PROXY. If nothing is configured (neither
/// explicit nor environment), client.http_proxy/https_proxy stay null — same
/// behavior as before this feature existed.
pub fn configure(
    allocator: std.mem.Allocator,
    client: *HttpClient,
    explicit_url: ?[]const u8,
    target_host: []const u8,
) !void {
    if (explicit_url) |url| {
        if (url.len > 0) {
            const proxy = try fromUrl(allocator, url) orelse return;
            client.http_proxy = proxy;
            client.https_proxy = proxy;
            return;
        }
    }

    if (fromEnv(allocator, .plain, target_host)) |proxy| client.http_proxy = proxy;
    if (fromEnv(allocator, .tls, target_host)) |proxy| client.https_proxy = proxy;
}

/// Builds an HttpClient.Proxy from a "scheme://[user:pass@]host[:port]" URL.
/// URL syntax errors are propagated (explicit config should fail loudly, not
/// silently); an unsupported scheme (neither http nor https) returns null.
fn fromUrl(allocator: std.mem.Allocator, url: []const u8) !?*HttpClient.Proxy {
    const uri = std.Uri.parse(url) catch try std.Uri.parseAfterScheme("http", url);
    const protocol = HttpClient.Protocol.fromUri(uri) orelse return null;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const parsed_host = try std.Io.net.HostName.fromUri(uri, &host_buf);
    const host: std.Io.net.HostName = .{ .bytes = try allocator.dupe(u8, parsed_host.bytes) };

    const authorization: ?[]const u8 = if (uri.user != null or uri.password != null) blk: {
        const buf = try allocator.alloc(u8, HttpClient.basic_authorization.valueLengthFromUri(uri));
        std.debug.assert(HttpClient.basic_authorization.value(uri, buf).len == buf.len);
        break :blk buf;
    } else null;

    const default_port: u16 = switch (protocol) {
        .plain => 80,
        .tls => 443,
    };

    const proxy = try allocator.create(HttpClient.Proxy);
    proxy.* = .{
        .protocol = protocol,
        .host = host,
        .authorization = authorization,
        .port = uri.port orelse default_port,
        .supports_connect = true,
    };
    return proxy;
}

/// Reads http_proxy/HTTPS_PROXY/all_proxy (depending on the protocol) from
/// the environment, honoring no_proxy/NO_PROXY. Best-effort: any error
/// (malformed env value, OOM) just makes this source get skipped, never
/// aborts the whole request.
fn fromEnv(allocator: std.mem.Allocator, protocol: HttpClient.Protocol, target_host: []const u8) ?*HttpClient.Proxy {
    if (getEnv("no_proxy") orelse getEnv("NO_PROXY")) |list| {
        if (isBypassed(list, target_host)) return null;
    }

    const names: []const []const u8 = switch (protocol) {
        .plain => &.{ "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY" },
        .tls => &.{ "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" },
    };

    for (names) |name| {
        const value = getEnv(name) orelse continue;
        if (value.len == 0) continue;
        return fromUrl(allocator, value) catch null;
    }
    return null;
}

/// Reads an environment variable with libc's getenv(). Requires the final
/// binary to link libc — already the case for this project's R2 driver
/// (modules/r2 uses link_libc = true). std.process.Environ.Map would require
/// threading std.process.Init through pacman's whole API, a much bigger
/// change than the scope of this feature.
///
/// getenv(), not a walk over `std.c.environ`: in a binary built with Zig
/// 0.17.0's incremental compilation (`-fincremental`, which `spider dev`
/// uses) that variable reads as a null pointer, and every request crashed
/// here. Function calls into libc are fine.
pub fn getEnv(name: []const u8) ?[]const u8 {
    var name_buf: [64]u8 = undefined;
    if (name.len >= name_buf.len) return null;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    const getenv = struct {
        extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    }.getenv;
    const value = getenv(@ptrCast(&name_buf)) orelse return null;
    return std.mem.span(value);
}

test "getEnv: reads the process environment through libc" {
    // PATH is set wherever the tests run; an unset name is null, and a name
    // too long to be a variable does not overflow the buffer.
    try std.testing.expect(getEnv("PATH") != null);
    try std.testing.expectEqual(@as(?[]const u8, null), getEnv("PACMAN_SURELY_NOT_SET_7f3a"));
    const long: [200]u8 = @splat('A');
    try std.testing.expectEqual(@as(?[]const u8, null), getEnv(&long));
}

/// Checks whether `host` should bypass the proxy, per the no_proxy/NO_PROXY
/// list.
///
/// SUPPORTED formats (comma-separated list):
///   - "*"                     disables the proxy for any host
///   - "example.com"           matches "example.com" AND any subdomain
///                             ("api.example.com", "a.b.example.com", ...)
///   - ".example.com"          equivalent to "example.com" above (the leading
///                             "." is just a common convention, treated the
///                             same)
///
/// NOT SUPPORTED (differs from curl/glibc in some cases):
///   - CIDR ("10.0.0.0/8")     not recognized as a range, only as a literal
///                             string (only matches if the host is literally
///                             "10.0.0.0/8", which never happens in practice)
///   - explicit port in no_proxy ("example.com:8080") — the port is ignored,
///     matching is by hostname only
fn isBypassed(no_proxy_list: []const u8, host: []const u8) bool {
    var it = std.mem.splitScalar(u8, no_proxy_list, ',');
    while (it.next()) |raw_entry| {
        const entry = std.mem.trim(u8, raw_entry, " \t");
        if (entry.len == 0) continue;
        if (std.mem.eql(u8, entry, "*")) return true;
        const pattern = if (entry[0] == '.') entry[1..] else entry;
        if (std.mem.eql(u8, host, pattern)) return true;
        if (std.mem.endsWith(u8, host, pattern) and host.len > pattern.len and host[host.len - pattern.len - 1] == '.') return true;
    }
    return false;
}

test "isBypassed matches exact host" {
    try std.testing.expect(isBypassed("localhost,127.0.0.1", "localhost"));
    try std.testing.expect(!isBypassed("localhost,127.0.0.1", "example.com"));
}

test "isBypassed matches subdomain suffix" {
    try std.testing.expect(isBypassed(".internal.example.com", "api.internal.example.com"));
    try std.testing.expect(isBypassed("internal.example.com", "api.internal.example.com"));
    try std.testing.expect(!isBypassed("internal.example.com", "notinternal.example.com"));
}

test "isBypassed wildcard disables proxy for everything" {
    try std.testing.expect(isBypassed("*", "anything.example.com"));
}

test "isBypassed does NOT treat CIDR as a range (documented limitation)" {
    // "10.0.0.0/8" only matches literally, not as an IP range.
    try std.testing.expect(!isBypassed("10.0.0.0/8", "10.1.2.3"));
}

test "fromUrl parses host, port and protocol" {
    // fromUrl allocates the proxy and its fields and never frees them one
    // by one — that's why this test uses an arena (matching real usage in
    // request()), not std.testing.allocator with a manual free per field.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const proxy = (try fromUrl(allocator, "http://proxy.example.com:8080")).?;

    try std.testing.expectEqual(HttpClient.Protocol.plain, proxy.protocol);
    try std.testing.expectEqualStrings("proxy.example.com", proxy.host.bytes);
    try std.testing.expectEqual(@as(u16, 8080), proxy.port);
    try std.testing.expect(proxy.authorization == null);
}

test "fromUrl parses userinfo into authorization header" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const proxy = (try fromUrl(allocator, "http://user:pass@proxy.example.com:3128")).?;

    try std.testing.expect(std.mem.startsWith(u8, proxy.authorization.?, "Basic "));
}

test "fromUrl defaults port from scheme" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const proxy = (try fromUrl(allocator, "https://proxy.example.com")).?;

    try std.testing.expectEqual(HttpClient.Protocol.tls, proxy.protocol);
    try std.testing.expectEqual(@as(u16, 443), proxy.port);
}
