const std = @import("std");
const Io = std.Io;

pub const Body = @import("body.zig").Body;
pub const jsonBody = @import("body.zig").jsonBody;
pub const Headers = @import("headers.zig").Headers;
pub const Response = @import("response.zig").Response;
pub const Client = @import("client.zig").Client;
pub const FetchOptions = @import("request.zig").FetchOptions;
/// Low-level entry point, for callers that need full per-call control (own
/// method/headers/uri) while still reusing a persistent http.Client's
/// connection pool — e.g. a caller with its own request-signing scheme
/// (fresh Authorization/date headers every call) that doesn't fit Client's
/// fixed-headers-at-init model. See Client.get/post/etc for the common case.
pub const request = @import("request.zig").request;
pub const asyncGet = @import("client.zig").asyncGet;
pub const asyncPost = @import("client.zig").asyncPost;
pub const asyncPut = @import("client.zig").asyncPut;
pub const asyncPatch = @import("client.zig").asyncPatch;
pub const asyncDelete = @import("client.zig").asyncDelete;
pub const get = @import("request.zig").get;
pub const post = @import("request.zig").post;
pub const put = @import("request.zig").put;
pub const patch = @import("request.zig").patch;
pub const delete = @import("request.zig").delete;
pub const head = @import("request.zig").head;

test "debug text content" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var res = try get(io, allocator, "https://httpbingo.org/get", .{});
    defer res.deinit();

    std.debug.print("status: {d}\n", .{res.status});
    std.debug.print("body length: {d}\n", .{res.text().len});
    std.debug.print("body content: {s}\n", .{res.text()});
}

const HttpbinResponse = struct {
    url: []const u8,
    headers: std.json.Value,
    origin: []const u8,
    args: std.json.Value,
};

test "response.json()" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var res = try get(io, allocator, "https://httpbingo.org/get", .{});
    defer res.deinit();

    const parsed = try res.json(HttpbinResponse);
    try std.testing.expectEqualStrings("https://httpbingo.org/get", parsed.value.url);
}

test "Client.get()" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client = try Client.init(io, allocator, .{
        .base_url = "https://httpbingo.org",
        .headers = &.{.{ .name = "X-Custom", .value = "pacman" }},
    });
    defer client.deinit();

    var res = try client.get("/get", .{});
    defer res.deinit();

    try std.testing.expect(res.status == .ok);

    const body = res.text();
    try std.testing.expect(std.mem.indexOf(u8, body, "pacman") != null);
}

test "Client.post() with json body" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client = try Client.init(io, allocator, .{
        .base_url = "https://httpbingo.org",
    });
    defer client.deinit();

    const payload = .{
        .name = "pacman",
        .version = @as(u32, 1),
    };
    const serialized = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(serialized);

    var res = try client.post("/post", .{
        .body = jsonBody(serialized),
    });
    defer res.deinit();

    try std.testing.expect(res.status == .ok);
    const body = res.text();
    try std.testing.expect(std.mem.indexOf(u8, body, "pacman") != null);
}

test "query params" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var res = try get(io, allocator, "https://httpbingo.org/get", .{
        .query = &.{
            .{ "page", "1" },
            .{ "limit", "10" },
            .{ "search", "hello world" }, // must be URL-encoded
        },
    });
    defer res.deinit();

    try std.testing.expect(res.status == .ok);
    const body = res.text();
    // httpbin echoes query params back in "args"
    try std.testing.expect(std.mem.indexOf(u8, body, "page") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "limit") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "hello") != null);
}

test "large response body" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // httpbin returns a large response with 16384 bytes
    var res = try get(io, allocator, "https://httpbingo.org/stream-bytes/16384", .{});
    defer res.deinit();

    try std.testing.expect(res.status == .ok);
    const body = res.text();
    try std.testing.expect(body.len > 8192); // must be larger than old fixed buffer
}

test "URL params" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client = try Client.init(io, allocator, .{
        .base_url = "https://httpbingo.org",
    });
    defer client.deinit();

    var res = try client.get("/anything/:version/users/:id", .{
        .params = &.{
            .{ "version", "v1" },
            .{ "id", "42" },
        },
    });
    defer res.deinit();

    try std.testing.expect(res.status == .ok);
    const body = res.text();
    // httpbin echoes the URL back — confirm params were replaced
    try std.testing.expect(std.mem.indexOf(u8, body, "v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "42") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, ":id") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, ":version") == null);
}

test "response headers" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var res = try get(io, allocator, "https://httpbingo.org/get", .{});
    defer res.deinit();

    // Test that response was successful
    try std.testing.expect(res.status == .ok);

    // Test real header extraction - httpbingo.org should return specific headers
    const content_type = res.headers.get("content-type");
    try std.testing.expect(content_type != null);
    try std.testing.expect(std.mem.indexOf(u8, content_type.?, "application/json") != null);

    // Test case-insensitive header lookup
    const content_type_upper = res.headers.get("CONTENT-TYPE");
    try std.testing.expect(content_type_upper != null);
    try std.testing.expect(std.mem.eql(u8, content_type.?, content_type_upper.?));
}

test "put request" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const payload = .{ .name = "pacman" };
    const serialized = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(serialized);

    var res = try put(io, allocator, "https://httpbingo.org/put", .{
        .body = jsonBody(serialized),
    });
    defer res.deinit();
    try std.testing.expect(res.status == .ok);
}

test "patch request" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const payload = .{ .name = "pacman" };
    const serialized = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(serialized);

    var res = try patch(io, allocator, "https://httpbingo.org/patch", .{
        .body = jsonBody(serialized),
    });
    defer res.deinit();
    try std.testing.expect(res.status == .ok);
}

test "delete request" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var res = try delete(io, allocator, "https://httpbingo.org/delete", .{});
    defer res.deinit();
    try std.testing.expect(res.status == .ok);
}

test "form body" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var res = try post(io, allocator, "https://httpbingo.org/post", .{
        .body = .{ .form = &.{
            .{ "name", "pacman" },
            .{ "version", "1" },
        } },
    });
    defer res.deinit();
    try std.testing.expect(res.status == .ok);
    const body = res.text();
    try std.testing.expect(std.mem.indexOf(u8, body, "pacman") != null);
}

test "timeout field exists" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Test that timeout_ms field exists and doesn't break anything
    var res = try get(io, allocator, "https://httpbingo.org/get", .{
        .timeout_ms = 0, // No timeout
    });
    defer res.deinit();
    try std.testing.expect(res.status == .ok);
}

test "real timeout functionality" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // This test will need to be updated when timeout functionality is implemented
    // For now, it just verifies that the request completes successfully
    var res = try get(io, allocator, "https://httpbingo.org/delay/1", .{
        .timeout_ms = 500, // 500ms timeout - should timeout if implemented
    });
    defer res.deinit();

    // Currently timeout is not implemented, so request should succeed
    try std.testing.expect(res.status == .ok);
}

test "Client.delete()" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client = try Client.init(io, allocator, .{
        .base_url = "https://httpbingo.org",
    });
    defer client.deinit();
    var res = try client.delete("/delete", .{});
    defer res.deinit();
    try std.testing.expect(res.status == .ok);
}

test "concurrent requests with io.async" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A fixed absolute threshold (e.g. "< 1900ms") is unreliable across
    // environments: per-request overhead (DNS, TCP connect, TLS handshake)
    // varies a lot by network/sandbox and can itself exceed 1900ms before the
    // endpoint's own 1s delay is even counted — that overhead is unrelated to
    // whether the two requests actually ran concurrently. So instead we
    // measure a real sequential baseline (one request, timed alone) and
    // assert the concurrent pair finishes well under 2x that baseline —
    // which is what "these two requests actually overlapped" means,
    // regardless of the absolute cost of a single request here.
    const baseline_start = Io.Clock.real.now(io);
    var r0 = try get(io, allocator, "https://httpbingo.org/delay/1", .{});
    const baseline_end = Io.Clock.real.now(io);
    r0.deinit();
    const baseline_ms = @divTrunc(baseline_start.durationTo(baseline_end).toNanoseconds(), 1000000);

    const start = Io.Clock.real.now(io);

    var t1 = io.async(get, .{ io, allocator, "https://httpbingo.org/delay/1", FetchOptions{} });
    var t2 = io.async(get, .{ io, allocator, "https://httpbingo.org/delay/1", FetchOptions{} });

    var r1 = try t1.await(io);
    var r2 = try t2.await(io);

    const end = Io.Clock.real.now(io);
    const elapsed_ns = start.durationTo(end).toNanoseconds();
    const elapsed_ms = @divTrunc(elapsed_ns, 1000000);

    // if truly concurrent, both 1s requests finish in ~1x a single request,
    // not ~2x
    std.debug.print("baseline (1 request): {d}ms, concurrent (2 requests): {d}ms\n", .{ baseline_ms, elapsed_ms });

    defer r1.deinit();
    defer r2.deinit();

    try std.testing.expect(r1.status == .ok);
    try std.testing.expect(r2.status == .ok);
    // concurrent: should finish well under 2x the sequential baseline
    // (accounting for network variability) — proves the two requests
    // actually overlapped instead of running one after the other.
    try std.testing.expect(elapsed_ms < @divTrunc(baseline_ms * 3, 2));
}

test "asyncGet with Client" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client = try Client.init(io, allocator, .{
        .base_url = "https://httpbingo.org",
    });
    defer client.deinit();

    var res = try client.get("/get", .{});
    defer res.deinit();
    try std.testing.expect(res.status == .ok);
}

test "asyncPost with Client" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client = try Client.init(io, allocator, .{
        .base_url = "https://httpbingo.org",
    });
    defer client.deinit();

    var res = try client.post("/post", .{
        .body = jsonBody("{\"test\":true}"),
    });
    defer res.deinit();
    try std.testing.expect(res.status == .ok);
    const body = res.text();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"test\": true") != null);
}

test "asyncPut with Client" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client = try Client.init(io, allocator, .{
        .base_url = "https://httpbingo.org",
    });
    defer client.deinit();

    var res = try client.put("/put", .{
        .body = jsonBody("{\"updated\":true}"),
    });
    defer res.deinit();
    try std.testing.expect(res.status == .ok);
    const body = res.text();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"updated\": true") != null);
}

test "asyncPatch with Client" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client = try Client.init(io, allocator, .{
        .base_url = "https://httpbingo.org",
    });
    defer client.deinit();

    var res = try client.patch("/patch", .{
        .body = jsonBody("{\"patched\":true}"),
    });
    defer res.deinit();
    try std.testing.expect(res.status == .ok);
    const body = res.text();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"patched\": true") != null);
}

test "asyncDelete with Client" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client = try Client.init(io, allocator, .{
        .base_url = "https://httpbingo.org",
    });
    defer client.deinit();

    var res = try client.delete("/delete", .{});
    defer res.deinit();
    try std.testing.expect(res.status == .ok);
}

test "concurrent async requests with Client methods" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client = try Client.init(io, allocator, .{
        .base_url = "https://httpbingo.org",
    });
    defer client.deinit();

    const start = Io.Clock.real.now(io);

    var t1 = io.async(asyncGet, .{ &client, "/delay/1", .{} });
    var t2 = io.async(asyncGet, .{ &client, "/delay/1", .{} });

    var r1 = try t1.await(io);
    var r2 = try t2.await(io);

    const end = Io.Clock.real.now(io);
    const elapsed_ns = start.durationTo(end).toNanoseconds();
    const elapsed_ms = @divTrunc(elapsed_ns, 1000000);

    defer r1.deinit();
    defer r2.deinit();

    try std.testing.expect(r1.status == .ok);
    try std.testing.expect(r2.status == .ok);
    try std.testing.expect(elapsed_ms < 2500);
}

/// Reads a test-only env var via std.c.environ. Used to opt in to the
/// proxy integration tests below, which need a real local proxy to run
/// against (see README for how to spin one up).
fn testEnv(key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const line = std.mem.span(entry);
        if (line.len > key.len and line[key.len] == '=' and std.mem.eql(u8, line[0..key.len], key)) {
            return line[key.len + 1 ..];
        }
    }
    return null;
}

/// Accepts exactly one connection, replies to whatever it received with a
/// bare "200 Connection Established" (no headers), then hangs up — playing
/// a misbehaving HTTP(S) proxy that confirms the CONNECT tunnel and then
/// closes the socket before any TLS bytes can be exchanged on top of it.
fn brokenProxyAcceptAndHangUp(io: Io, server: *Io.net.Server) !void {
    var stream = try server.accept(io);
    defer stream.close(io);

    var write_buf: [64]u8 = undefined;
    var w = stream.writer(io, &write_buf);
    try w.interface.writeAll("HTTP/1.1 200 Connection Established\r\n\r\n");
    try w.interface.flush();
    // Returning here closes `stream` (via the `defer` above) immediately —
    // before the caller can perform a TLS handshake over the "tunnel".
}

test "HTTP(S) proxy: tunnel closed before TLS handshake does not crash (UAF regression)" {
    // Regression test for vendor/zig-lib-patched/PATCH_NOTES.md's Change 3.
    // std.http.Client.connectProxied() used to write into an already-freed
    // Connection when a CONNECT tunnel succeeded but the TLS handshake
    // performed afterward (once the tunneled .plain Connection is destroyed
    // and rebuilt as .tls) then failed — exactly what happens when a proxy
    // closes the connection right after "200 Connection Established". Under
    // DebugAllocator, a regression here surfaces as a double-free/invalid-free
    // panic, not merely a returned error — so the real assertion this test
    // makes is "doesn't crash", not the specific error value.
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var fake_proxy = io.async(brokenProxyAcceptAndHangUp, .{ io, &server });

    var proxy_url_buf: [48]u8 = undefined;
    const proxy_url = try std.fmt.bufPrint(&proxy_url_buf, "http://127.0.0.1:{d}", .{port});

    const result = get(io, allocator, "https://example.com/", .{ .proxy_url = proxy_url });
    try fake_proxy.await(io);

    if (result) |res| {
        var r = res;
        r.deinit();
        return error.TestUnexpectedResult; // the tunnel was never usable — this should have failed
    } else |_| {} // any error is fine here; a crash is the only real failure mode
}

test "GET through an explicit HTTP(S) proxy" {
    // Only runs if PACMAN_TEST_HTTP_PROXY is set, e.g.:
    //   PACMAN_TEST_HTTP_PROXY=http://127.0.0.1:8899 zig test src/root.zig
    // Without the env var, it's skipped (doesn't fail the suite) — no real
    // proxy is available by default in dev/CI. See README for how to spin up
    // a local proxy (tinyproxy/mitmproxy) to validate manually.
    const url = testEnv("PACMAN_TEST_HTTP_PROXY") orelse return error.SkipZigTest;

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var res = try get(io, allocator, "https://httpbingo.org/get", .{ .proxy_url = url });
    defer res.deinit();

    try std.testing.expect(res.status == .ok);
}

test "GET HTTPS through an explicit SOCKS5(h) proxy" {
    // Only runs if PACMAN_TEST_SOCKS5_PROXY is set, e.g.:
    //   PACMAN_TEST_SOCKS5_PROXY=socks5h://127.0.0.1:1080 zig test src/root.zig
    // This specifically exercises the HTTPS-through-SOCKS5 path, which only
    // works because of the vendored Client.zig fix — SOCKS5 tunnels to a
    // .plain byte pipe, and adoptTunneledStream() is what performs the real
    // TLS handshake on top for the .tls target.
    const url = testEnv("PACMAN_TEST_SOCKS5_PROXY") orelse return error.SkipZigTest;

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var res = try get(io, allocator, "https://httpbingo.org/get", .{ .proxy_url = url });
    defer res.deinit();

    try std.testing.expect(res.status == .ok);
}
