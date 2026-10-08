// The HTTP client against scripted local servers: no network needed.
//
//   zig build test-pacman-local                    # threaded backend
//   zig build test-pacman-local -Dio_backend=zio   # zio (what production runs)
//
// Each test starts a tiny server on 127.0.0.1 that follows a script per
// connection — send these bytes, pause, hold the connection open, hang up —
// so the test controls exactly what the client sees and when. The server
// runs on its own OS thread with its own blocking Io, whatever backend the
// client under test is using.
const std = @import("std");
const pacman = @import("pacman");
const options = @import("local_test_options");
const Io = std.Io;
const t = std.testing;

// ── the Io under test ───────────────────────────────────────────────────

const Backend = if (options.zio) struct {
    const zio = @import("zio");
    rt: *zio.Runtime,

    fn init() !@This() {
        return .{ .rt = try zio.Runtime.init(std.heap.smp_allocator, .{ .executors = .auto }) };
    }
    fn deinit(self: *@This()) void {
        self.rt.deinit();
    }
    fn io(self: *@This()) Io {
        return self.rt.io();
    }
} else struct {
    threaded: Io.Threaded,

    fn init() !@This() {
        return .{ .threaded = .init(std.heap.smp_allocator, .{}) };
    }
    fn deinit(self: *@This()) void {
        self.threaded.deinit();
    }
    fn io(self: *@This()) Io {
        return self.threaded.io();
    }
};

const backend_name = if (options.zio) "zio" else "threaded";

// ── scripted server ─────────────────────────────────────────────────────

const Step = union(enum) {
    /// Send these bytes.
    send: []const u8,
    /// Wait before the next step.
    pause_ms: u32,
    /// Keep the connection open and wait for the CLIENT to close it, for at
    /// most `hold_limit_ms`. Records whether the client did.
    hold,
};

/// What the server does on one accepted connection, after reading the
/// request. The connection is closed when the script ends.
const Script = []const Step;

const hold_limit_ms = 3000;

const Server = struct {
    threaded: Io.Threaded,
    listener: Io.net.Server,
    port: u16,
    scripts: []const Script,
    thread: std.Thread,
    accepted: std.atomic.Value(usize) = .init(0),
    /// Connections the CLIENT closed while the server was holding them.
    closed_by_client: std.atomic.Value(usize) = .init(0),
    /// Holds that ran out the clock with the client still connected.
    hold_expired: std.atomic.Value(usize) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),

    fn start(scripts: []const Script) !*Server {
        const self = try std.heap.smp_allocator.create(Server);
        errdefer std.heap.smp_allocator.destroy(self);
        self.* = .{
            .threaded = .init(std.heap.smp_allocator, .{}),
            .listener = undefined,
            .port = 0,
            .scripts = scripts,
            .thread = undefined,
        };
        const io = self.threaded.io();
        var addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        self.listener = try addr.listen(io, .{ .reuse_address = true });
        self.port = self.listener.socket.address.getPort();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Stops the server even if fewer connections arrived than scripted.
    fn stop(self: *Server) void {
        const io = self.threaded.io();
        self.stopping.store(true, .seq_cst);
        // Wake a pending accept().
        if (Io.net.IpAddress.parseIp4("127.0.0.1", self.port)) |addr| {
            if (addr.connect(io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        } else |_| {}
        self.thread.join();
        self.listener.deinit(io);
        self.threaded.deinit();
        std.heap.smp_allocator.destroy(self);
    }

    fn url(self: *const Server, buf: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ self.port, path }) catch unreachable;
    }

    fn run(self: *Server) void {
        const io = self.threaded.io();
        for (self.scripts) |script| {
            const stream = self.listener.accept(io) catch return;
            defer stream.close(io);
            if (self.stopping.load(.seq_cst)) return;
            _ = self.accepted.fetchAdd(1, .seq_cst);

            var buf: [8192]u8 = undefined;
            if ((readSome(io, stream, &buf) catch 0) == 0) continue;

            for (script) |step| switch (step) {
                .send => |bytes| writeAll(io, stream, bytes) catch break,
                .pause_ms => |ms| Io.sleep(io, .fromMilliseconds(ms), .awake) catch {},
                .hold => {
                    switch (waitForClose(stream, hold_limit_ms)) {
                        .closed => _ = self.closed_by_client.fetchAdd(1, .seq_cst),
                        .still_open => _ = self.hold_expired.fetchAdd(1, .seq_cst),
                    }
                    break;
                },
            };
        }
    }

    /// Waits until the peer closes the connection, for at most `ms`. Plain
    /// poll + read on the descriptor: this must not depend on the Io
    /// machinery the test is about.
    fn waitForClose(stream: Io.net.Stream, ms: u32) enum { closed, still_open } {
        const fd = stream.socket.handle;
        var waited: u32 = 0;
        var discard: [1024]u8 = undefined;
        while (waited < ms) : (waited += 50) {
            var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, 50) catch return .closed;
            if (ready == 0) continue;
            const n = std.posix.read(fd, &discard) catch return .closed;
            if (n == 0) return .closed;
        }
        return .still_open;
    }

    fn readSome(io: Io, stream: Io.net.Stream, buf: []u8) !usize {
        var vecs: [1][]u8 = .{buf};
        var reader = stream.reader(io, &.{});
        return reader.interface.readVec(&vecs);
    }

    fn writeAll(io: Io, stream: Io.net.Stream, data: []const u8) !void {
        var wbuf: [1024]u8 = undefined;
        var writer = stream.writer(io, &wbuf);
        try writer.interface.writeAll(data);
        try writer.interface.flush();
    }
};

fn elapsedMs(io: Io, since: Io.Timestamp) i64 {
    return since.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();
}

const ok_response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello";

// ── phase 0: does racing a clock actually interrupt a blocked request? ──
// These two tests race the request against a clock HERE, in the test, to
// answer the question before the client grows a timeout of its own. They
// stay as the direct proof that cancelation interrupts a blocked network
// read on this backend — the property the client's timeout is built on.

const Race = union(enum) {
    response: anyerror!pacman.Response,
    clock: Io.Cancelable!void,
};

fn fetchNoTimeout(io: Io, url: []const u8) anyerror!pacman.Response {
    return pacman.get(io, std.heap.smp_allocator, url, .{});
}

/// Returns true if the clock won and canceling the request returned
/// promptly.
fn raceAgainstClock(io: Io, url: []const u8, ms: u32) !bool {
    var buf: [2]Race = undefined;
    var select: Io.Select(Race) = .init(io, &buf);
    try select.concurrent(.response, fetchNoTimeout, .{ io, url });
    try select.concurrent(.clock, Io.sleep, .{ io, Io.Duration.fromMilliseconds(ms), Io.Clock.awake });

    const first = try select.await();
    var clock_won = false;
    switch (first) {
        .clock => clock_won = true,
        .response => |r| if (r) |resp| {
            var owned = resp;
            owned.deinit();
        } else |_| {},
    }
    // Cancel whatever is left and wait for it. If canceling could NOT
    // interrupt the blocked read, this is where the test would sit until
    // the server gave up.
    while (select.cancel()) |rest| switch (rest) {
        .response => |r| if (r) |resp| {
            var owned = resp;
            owned.deinit();
        } else |_| {},
        .clock => {},
    };
    return clock_won;
}

test "phase 0: canceling interrupts a request blocked waiting for the response head" {
    var backend = try Backend.init();
    defer backend.deinit();
    const io = backend.io();

    const server = try Server.start(&.{&.{.hold}});
    defer server.stop();
    var url_buf: [64]u8 = undefined;

    const started = Io.Timestamp.now(io, .awake);
    try t.expect(try raceAgainstClock(io, server.url(&url_buf, "/"), 300));
    const took = elapsedMs(io, started);
    std.debug.print("[{s}] blocked on the head: canceled after {d} ms (server would hold {d} ms)\n", .{ backend_name, took, hold_limit_ms });
    try t.expect(took < 1500);
}

test "phase 0: canceling interrupts a request blocked in the middle of the body" {
    var backend = try Backend.init();
    defer backend.deinit();
    const io = backend.io();

    const server = try Server.start(&.{&.{
        .{ .send = "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\nonly the beginning" },
        .hold,
    }});
    defer server.stop();
    var url_buf: [64]u8 = undefined;

    const started = Io.Timestamp.now(io, .awake);
    try t.expect(try raceAgainstClock(io, server.url(&url_buf, "/"), 300));
    const took = elapsedMs(io, started);
    std.debug.print("[{s}] blocked on the body: canceled after {d} ms\n", .{ backend_name, took });
    try t.expect(took < 1500);
}

test "phase 0: control — a server that answers is not canceled" {
    var backend = try Backend.init();
    defer backend.deinit();
    const io = backend.io();

    const server = try Server.start(&.{&.{.{ .send = ok_response }}});
    defer server.stop();
    var url_buf: [64]u8 = undefined;
    try t.expect(!(try raceAgainstClock(io, server.url(&url_buf, "/"), 2000)));
}

// ── phase 1: timeout_ms is a deadline for the whole request ─────────────

test "timeout: a server that accepts and never answers" {
    var backend = try Backend.init();
    defer backend.deinit();
    const io = backend.io();

    const server = try Server.start(&.{&.{.hold}});
    defer server.stop();
    var url_buf: [64]u8 = undefined;

    const started = Io.Timestamp.now(io, .awake);
    try t.expectError(error.Timeout, pacman.get(io, t.allocator, server.url(&url_buf, "/"), .{ .timeout_ms = 300 }));
    const took = elapsedMs(io, started);
    try t.expect(took >= 250 and took < 1500);
}

test "timeout: a server that sends the head and stalls in the body" {
    var backend = try Backend.init();
    defer backend.deinit();
    const io = backend.io();

    const server = try Server.start(&.{&.{
        .{ .send = "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\nonly the beginning" },
        .hold,
    }});
    defer server.stop();
    var url_buf: [64]u8 = undefined;

    const started = Io.Timestamp.now(io, .awake);
    try t.expectError(error.Timeout, pacman.post(io, t.allocator, server.url(&url_buf, "/"), .{ .timeout_ms = 300, .body = .{ .raw = "{}" } }));
    try t.expect(elapsedMs(io, started) < 1500);
}

test "timeout: a slow server inside the deadline is not cut" {
    var backend = try Backend.init();
    defer backend.deinit();
    const io = backend.io();

    const server = try Server.start(&.{&.{ .{ .pause_ms = 300 }, .{ .send = ok_response } }});
    defer server.stop();
    var url_buf: [64]u8 = undefined;

    var res = try pacman.get(io, t.allocator, server.url(&url_buf, "/"), .{ .timeout_ms = 3000 });
    defer res.deinit();
    try t.expectEqual(std.http.Status.ok, res.status);
    try t.expectEqualStrings("hello", res.text());
}

test "timeout: timeout_ms = 0 keeps waiting, as before" {
    var backend = try Backend.init();
    defer backend.deinit();
    const io = backend.io();

    const server = try Server.start(&.{&.{ .{ .pause_ms = 700 }, .{ .send = ok_response } }});
    defer server.stop();
    var url_buf: [64]u8 = undefined;

    const started = Io.Timestamp.now(io, .awake);
    var res = try pacman.get(io, t.allocator, server.url(&url_buf, "/"), .{});
    defer res.deinit();
    try t.expectEqualStrings("hello", res.text());
    try t.expect(elapsedMs(io, started) >= 650);
}

test "timeout: the connection is closed when the deadline passes" {
    var backend = try Backend.init();
    defer backend.deinit();
    const io = backend.io();

    const server = try Server.start(&.{&.{.hold}});
    var url_buf: [64]u8 = undefined;
    try t.expectError(error.Timeout, pacman.get(io, t.allocator, server.url(&url_buf, "/"), .{ .timeout_ms = 300 }));

    // The server notices the close well before its own hold runs out.
    Io.sleep(io, .fromMilliseconds(500), .awake) catch {};
    const closed = server.closed_by_client.load(.seq_cst);
    const expired = server.hold_expired.load(.seq_cst);
    server.stop();
    try t.expectEqual(@as(usize, 1), closed);
    try t.expectEqual(@as(usize, 0), expired);
}

test "timeout: a persistent Client does not reuse the connection that timed out" {
    var backend = try Backend.init();
    defer backend.deinit();
    const io = backend.io();

    // First connection: never answers. Second: answers.
    const server = try Server.start(&.{ &.{.hold}, &.{.{ .send = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello" }} });
    var base_buf: [64]u8 = undefined;
    var client = try pacman.Client.init(io, t.allocator, .{ .base_url = server.url(&base_buf, "") });
    defer client.deinit();

    try t.expectError(error.Timeout, client.get("/first", .{ .timeout_ms = 300 }));
    var res = try client.get("/second", .{ .timeout_ms = 3000 });
    defer res.deinit();
    try t.expectEqualStrings("hello", res.text());

    Io.sleep(io, .fromMilliseconds(300), .awake) catch {};
    const accepted = server.accepted.load(.seq_cst);
    const closed = server.closed_by_client.load(.seq_cst);
    server.stop();
    // A second connection was opened, and the first one was closed.
    try t.expectEqual(@as(usize, 2), accepted);
    try t.expectEqual(@as(usize, 1), closed);
}

test "a request that fails midway returns at once and closes its connection" {
    var backend = try Backend.init();
    defer backend.deinit();
    const io = backend.io();

    // A redirect is something this client does not follow: the request
    // fails after the response head arrived, with the server still holding
    // the connection open. No deadline here — the failure itself must not
    // wait for the server.
    const server = try Server.start(&.{&.{ .{ .send = "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:9/elsewhere\r\nContent-Length: 0\r\n\r\n" }, .hold }});
    var url_buf: [64]u8 = undefined;

    const started = Io.Timestamp.now(io, .awake);
    try t.expectError(error.HttpRedirectLocationOversize, pacman.get(io, t.allocator, server.url(&url_buf, "/"), .{}));
    try t.expect(elapsedMs(io, started) < 500);

    Io.sleep(io, .fromMilliseconds(300), .awake) catch {};
    const closed = server.closed_by_client.load(.seq_cst);
    server.stop();
    try t.expectEqual(@as(usize, 1), closed);
}

// ── phase 2: a body cut in the middle is an error ───────────────────────

fn expectCutBody(io: Io, script: Script) !void {
    const server = try Server.start(&.{script});
    defer server.stop();
    var url_buf: [64]u8 = undefined;
    if (pacman.get(io, t.allocator, server.url(&url_buf, "/"), .{})) |res| {
        var owned = res;
        defer owned.deinit();
        std.debug.print("got a response instead of an error: status {d}, {d} bytes: \"{s}\"\n", .{ @backingInt(owned.status), owned.text().len, owned.text() });
        return error.PartialBodyReturnedAsSuccess;
    } else |err| {
        try t.expectEqual(error.HttpBodyCutShort, err);
    }
}

test "cut body: Content-Length promised more than the server sent" {
    var backend = try Backend.init();
    defer backend.deinit();
    try expectCutBody(backend.io(), &.{.{ .send = "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\nonly the beginning" }});
}

test "cut body: chunked response that ends before the last chunk" {
    var backend = try Backend.init();
    defer backend.deinit();
    try expectCutBody(backend.io(), &.{.{ .send = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n400\r\nstart of a big chunk" }});
}

test "cut body: control — complete bodies still arrive whole" {
    var backend = try Backend.init();
    defer backend.deinit();
    const io = backend.io();

    const server = try Server.start(&.{
        &.{.{ .send = ok_response }},
        &.{.{ .send = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n" }},
        // No length at all: the body is whatever arrives until the server
        // hangs up. There is nothing to compare against, so this is whole.
        &.{.{ .send = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nuntil the end" }},
    });
    defer server.stop();
    var url_buf: [64]u8 = undefined;

    inline for (.{ "hello", "hello world", "until the end" }) |expected| {
        var res = try pacman.get(io, t.allocator, server.url(&url_buf, "/"), .{});
        defer res.deinit();
        try t.expectEqualStrings(expected, res.text());
    }
}

// ── phase 3: a response larger than the limit is refused ────────────────

const gz_2mib = @embedFile("testdata/2mib_of_a.gz"); // 2 MiB of 'a', ~2 KB gzipped
const two_mib = 2 * 1024 * 1024;

fn gzipResponse(comptime close: bool) []const u8 {
    return std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: {d}\r\n{s}\r\n", .{
        gz_2mib.len,
        if (close) "Connection: close\r\n" else "",
    }) ++ gz_2mib;
}

fn bigResponse(a: std.mem.Allocator, comptime head: []const u8, n: usize) ![]const u8 {
    const body = try a.alloc(u8, n);
    @memset(body, 'x');
    return std.fmt.allocPrint(a, head ++ "{s}", .{body});
}

test "size limit: a body over max_response_bytes is refused" {
    var backend = try Backend.init();
    defer backend.deinit();
    const io = backend.io();
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    const with_length = try bigResponse(arena.allocator(), "HTTP/1.1 200 OK\r\nContent-Length: 5000\r\nConnection: close\r\n\r\n", 5000);
    const no_length = try bigResponse(arena.allocator(), "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n", 5000);
    const server = try Server.start(&.{
        &.{.{ .send = with_length }}, &.{.{ .send = no_length }},
        &.{.{ .send = with_length }}, &.{.{ .send = with_length }},
    });
    defer server.stop();
    var url_buf: [64]u8 = undefined;
    const url = server.url(&url_buf, "/");

    // Declared length over the limit, and an undeclared one that runs over.
    try t.expectError(error.ResponseTooLarge, pacman.get(io, t.allocator, url, .{ .max_response_bytes = 1000 }));
    try t.expectError(error.ResponseTooLarge, pacman.get(io, t.allocator, url, .{ .max_response_bytes = 1000 }));
    // Exactly at the limit is fine; and so is the default.
    inline for (.{ pacman.FetchOptions{ .max_response_bytes = 5000 }, pacman.FetchOptions{} }) |opts| {
        var res = try pacman.get(io, t.allocator, url, opts);
        defer res.deinit();
        try t.expectEqual(@as(usize, 5000), res.text().len);
    }
}

test "size limit: counts the body AFTER decompression" {
    var backend = try Backend.init();
    defer backend.deinit();
    const io = backend.io();

    const server = try Server.start(&.{ &.{.{ .send = comptime gzipResponse(true) }}, &.{.{ .send = comptime gzipResponse(true) }} });
    defer server.stop();
    var url_buf: [64]u8 = undefined;
    const url = server.url(&url_buf, "/");

    // ~2 KB on the wire, 2 MiB once inflated: over a 64 KiB limit.
    try t.expect(gz_2mib.len < 4096);
    try t.expectError(error.ResponseTooLarge, pacman.get(io, t.allocator, url, .{ .max_response_bytes = 64 * 1024 }));
    // Control: the same response under a limit that fits it.
    var res = try pacman.get(io, t.allocator, url, .{ .max_response_bytes = 4 * 1024 * 1024 });
    defer res.deinit();
    try t.expectEqual(@as(usize, two_mib), res.text().len);
    try t.expectEqual(@as(u8, 'a'), res.text()[two_mib - 1]);
}

test "size limit: a declared length over the limit is refused before the body is read" {
    var backend = try Backend.init();
    defer backend.deinit();
    const io = backend.io();

    // Promises 10 GB and then sends nothing: the refusal must not wait for it.
    const server = try Server.start(&.{&.{ .{ .send = "HTTP/1.1 200 OK\r\nContent-Length: 10000000000\r\n\r\n" }, .hold }});
    defer server.stop();
    var url_buf: [64]u8 = undefined;

    const started = Io.Timestamp.now(io, .awake);
    try t.expectError(error.ResponseTooLarge, pacman.get(io, t.allocator, server.url(&url_buf, "/"), .{}));
    try t.expect(elapsedMs(io, started) < 500);
}

test "size limit: the default is generous" {
    try t.expect(pacman.default_max_response_bytes >= 32 * 1024 * 1024);
    try t.expectEqual(pacman.default_max_response_bytes, (pacman.FetchOptions{}).max_response_bytes);
}

// ── connection reuse and proxies ────────────────────────────────────────

/// A server that keeps connections alive and answers every request on them,
/// one thread per connection. It can also play the proxy in front of
/// itself: after a CONNECT or a SOCKS5 handshake it answers the tunneled
/// requests as the origin would.
const LiveServer = struct {
    const Role = enum { origin, connect_proxy, socks5_proxy };

    threaded: Io.Threaded,
    listener: Io.net.Server,
    port: u16,
    role: Role,
    /// connect_proxy: a CONNECT without this exact `proxy-authorization`
    /// value gets a 407 and the connection is closed.
    required_proxy_auth: ?[]const u8,
    /// What every request is answered with. Set before the first request.
    reply: []const u8 = answer,
    thread: std.Thread,
    stopping: std.atomic.Value(bool) = .init(false),
    active: std.atomic.Value(usize) = .init(0),
    accepted: std.atomic.Value(usize) = .init(0),
    /// Requests answered with 200 (tunneled or direct).
    answered: std.atomic.Value(usize) = .init(0),
    /// CONNECTs / SOCKS5 handshakes accepted.
    tunnels: std.atomic.Value(usize) = .init(0),
    /// CONNECTs refused with 407.
    refused: std.atomic.Value(usize) = .init(0),
    /// Requests that reached the proxy outside a tunnel (`GET http://…`).
    forwarded: std.atomic.Value(usize) = .init(0),

    const answer = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello";

    fn start(role: Role, required_proxy_auth: ?[]const u8) !*LiveServer {
        const self = try std.heap.smp_allocator.create(LiveServer);
        errdefer std.heap.smp_allocator.destroy(self);
        self.* = .{
            .threaded = .init(std.heap.smp_allocator, .{}),
            .listener = undefined,
            .port = 0,
            .role = role,
            .required_proxy_auth = required_proxy_auth,
            .thread = undefined,
        };
        const io = self.threaded.io();
        var addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        self.listener = try addr.listen(io, .{ .reuse_address = true });
        self.port = self.listener.socket.address.getPort();
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    /// Call after the client closed its connections.
    fn stop(self: *LiveServer) void {
        const io = self.threaded.io();
        self.stopping.store(true, .seq_cst);
        if (Io.net.IpAddress.parseIp4("127.0.0.1", self.port)) |addr| {
            if (addr.connect(io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        } else |_| {}
        self.thread.join();
        var waited: u32 = 0;
        while (self.active.load(.seq_cst) != 0 and waited < 3000) : (waited += 20) {
            Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
        }
        self.listener.deinit(io);
        self.threaded.deinit();
        std.heap.smp_allocator.destroy(self);
    }

    fn acceptLoop(self: *LiveServer) void {
        const io = self.threaded.io();
        while (true) {
            const stream = self.listener.accept(io) catch return;
            if (self.stopping.load(.seq_cst)) {
                stream.close(io);
                return;
            }
            _ = self.accepted.fetchAdd(1, .seq_cst);
            _ = self.active.fetchAdd(1, .seq_cst);
            const thread = std.Thread.spawn(.{}, serve, .{ self, stream }) catch {
                _ = self.active.fetchSub(1, .seq_cst);
                stream.close(io);
                continue;
            };
            thread.detach();
        }
    }

    fn serve(self: *LiveServer, stream: Io.net.Stream) void {
        const io = self.threaded.io();
        defer {
            stream.close(io);
            _ = self.active.fetchSub(1, .seq_cst);
        }
        var buf: [8192]u8 = undefined;

        if (self.role == .socks5_proxy) {
            // Greeting, then the CONNECT request; the client waits for each
            // reply, so each arrives as one read.
            if ((Server.readSome(io, stream, &buf) catch 0) == 0) return;
            Server.writeAll(io, stream, "\x05\x00") catch return;
            if ((Server.readSome(io, stream, &buf) catch 0) == 0) return;
            Server.writeAll(io, stream, "\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00") catch return;
            _ = self.tunnels.fetchAdd(1, .seq_cst);
        }

        while (true) {
            const head = readHead(io, stream, &buf) orelse return;
            if (std.mem.startsWith(u8, head, "CONNECT ")) {
                if (self.required_proxy_auth) |required| {
                    const given = headerValue(head, "proxy-authorization") orelse "";
                    if (!std.mem.eql(u8, given, required)) {
                        _ = self.refused.fetchAdd(1, .seq_cst);
                        Server.writeAll(io, stream, "HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n") catch {};
                        return;
                    }
                }
                _ = self.tunnels.fetchAdd(1, .seq_cst);
                Server.writeAll(io, stream, "HTTP/1.1 200 Connection Established\r\n\r\n") catch return;
                continue;
            }
            if (self.role == .connect_proxy and std.mem.indexOf(u8, head[0 .. std.mem.indexOf(u8, head, "\r\n") orelse head.len], "://") != null) {
                _ = self.forwarded.fetchAdd(1, .seq_cst);
            }
            _ = self.answered.fetchAdd(1, .seq_cst);
            Server.writeAll(io, stream, self.reply) catch return;
        }
    }

    /// One request head (these tests send no bodies), or null once the
    /// client closed the connection.
    fn readHead(io: Io, stream: Io.net.Stream, buf: []u8) ?[]const u8 {
        var len: usize = 0;
        while (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n") == null) {
            if (len == buf.len) return null;
            const n = Server.readSome(io, stream, buf[len..]) catch return null;
            if (n == 0) return null;
            len += n;
        }
        return buf[0..len];
    }

    fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        _ = lines.next();
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
        return null;
    }

    fn url(self: *const LiveServer, buf: []u8, comptime scheme_and_userinfo: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, scheme_and_userinfo ++ "127.0.0.1:{d}", .{self.port}) catch unreachable;
    }
};

fn getThree(client: *pacman.Client) !void {
    for (0..3) |_| {
        var res = try client.get("/", .{ .timeout_ms = 3000 });
        defer res.deinit();
        try t.expectEqualStrings("hello", res.text());
    }
}

test "reuse: a persistent Client sends consecutive requests on one connection" {
    var backend = try Backend.init();
    defer backend.deinit();
    const io = backend.io();

    const origin = try LiveServer.start(.origin, null);
    var base_buf: [64]u8 = undefined;
    {
        var client = try pacman.Client.init(io, t.allocator, .{ .base_url = origin.url(&base_buf, "http://") });
        defer client.deinit();
        try getThree(&client);
    }
    const accepted = origin.accepted.load(.seq_cst);
    const answered = origin.answered.load(.seq_cst);
    origin.stop();
    try t.expectEqual(@as(usize, 3), answered);
    try t.expectEqual(@as(usize, 1), accepted);
}

test "reuse: through SOCKS5, a persistent Client opens one tunnel" {
    var backend = try Backend.init();
    defer backend.deinit();
    const io = backend.io();

    const proxy = try LiveServer.start(.socks5_proxy, null);
    var proxy_buf: [64]u8 = undefined;
    {
        var client = try pacman.Client.init(io, t.allocator, .{
            .base_url = "http://origin.test",
            .proxy_url = proxy.url(&proxy_buf, "socks5h://"),
        });
        defer client.deinit();
        try getThree(&client);
    }
    const tunnels = proxy.tunnels.load(.seq_cst);
    const answered = proxy.answered.load(.seq_cst);
    proxy.stop();
    try t.expectEqual(@as(usize, 3), answered);
    try t.expectEqual(@as(usize, 1), tunnels);
}

test "http proxy: CONNECT carries the proxy credentials" {
    var backend = try Backend.init();
    defer backend.deinit();
    const io = backend.io();

    // "user:pass" in base64.
    const proxy = try LiveServer.start(.connect_proxy, "Basic dXNlcjpwYXNz");
    var proxy_buf: [64]u8 = undefined;
    {
        var client = try pacman.Client.init(io, t.allocator, .{
            .base_url = "http://origin.test",
            .proxy_url = proxy.url(&proxy_buf, "http://user:pass@"),
        });
        defer client.deinit();
        try getThree(&client);
    }
    const refused = proxy.refused.load(.seq_cst);
    const tunnels = proxy.tunnels.load(.seq_cst);
    const forwarded = proxy.forwarded.load(.seq_cst);
    proxy.stop();
    try t.expectEqual(@as(usize, 0), refused);
    try t.expectEqual(@as(usize, 1), tunnels);
    try t.expectEqual(@as(usize, 0), forwarded);
}

test "http proxy: an https request is never sent to the proxy outside a tunnel" {
    var backend = try Backend.init();
    defer backend.deinit();
    const io = backend.io();

    // The proxy refuses every CONNECT (the credentials are wrong).
    const proxy = try LiveServer.start(.connect_proxy, "Basic bm90LXRoaXM=");
    var proxy_buf: [64]u8 = undefined;
    const proxy_url = proxy.url(&proxy_buf, "http://user:pass@");

    const result = pacman.get(io, t.allocator, "https://origin.test/secret", .{ .proxy_url = proxy_url, .timeout_ms = 3000 });
    if (result) |res| {
        var r = res;
        r.deinit();
    } else |_| {}
    Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
    const refused = proxy.refused.load(.seq_cst);
    const forwarded = proxy.forwarded.load(.seq_cst);
    const answered = proxy.answered.load(.seq_cst);
    proxy.stop();
    try t.expect(std.meta.isError(result));
    try t.expectEqual(@as(usize, 1), refused);
    try t.expectEqual(@as(usize, 0), forwarded);
    try t.expectEqual(@as(usize, 0), answered);
}

/// Three requests on one persistent Client, each answered with `reply`;
/// returns how many connections the server saw.
fn connectionsForThree(io: Io, reply: []const u8, expected_len: usize) !usize {
    const origin = try LiveServer.start(.origin, null);
    origin.reply = reply;
    var base_buf: [64]u8 = undefined;
    var failed: ?anyerror = null;
    {
        var client = try pacman.Client.init(io, t.allocator, .{ .base_url = origin.url(&base_buf, "http://") });
        defer client.deinit();
        for (0..3) |_| {
            var res = client.get("/", .{ .timeout_ms = 3000 }) catch |err| {
                failed = err;
                break;
            };
            defer res.deinit();
            if (res.text().len != expected_len) failed = error.TestUnexpectedResult;
        }
    }
    const accepted = origin.accepted.load(.seq_cst);
    origin.stop();
    if (failed) |err| return err;
    return accepted;
}

test "reuse: a gzip response leaves the connection reusable" {
    var backend = try Backend.init();
    defer backend.deinit();
    try t.expectEqual(@as(usize, 1), try connectionsForThree(backend.io(), comptime gzipResponse(false), two_mib));
}

test "reuse: a chunked response leaves the connection reusable" {
    var backend = try Backend.init();
    defer backend.deinit();
    const chunked = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n";
    try t.expectEqual(@as(usize, 1), try connectionsForThree(backend.io(), chunked, 11));
}

test "reuse: a chunked gzip response leaves the connection reusable" {
    var backend = try Backend.init();
    defer backend.deinit();
    const chunked_gzip = comptime std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n{x}\r\n", .{gz_2mib.len}) ++ gz_2mib ++ "\r\n0\r\n\r\n";
    try t.expectEqual(@as(usize, 1), try connectionsForThree(backend.io(), chunked_gzip, two_mib));
}

test "HEAD: a response that names a compressed body returns at once, empty" {
    var backend = try Backend.init();
    defer backend.deinit();
    const io = backend.io();

    const origin = try LiveServer.start(.origin, null);
    origin.reply = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 2048\r\n\r\n";
    var url_buf: [64]u8 = undefined;
    const started = Io.Timestamp.now(io, .awake);
    const result = pacman.head(io, t.allocator, origin.url(&url_buf, "http://"), .{ .timeout_ms = 2000 });
    const took = elapsedMs(io, started);
    var len: usize = 1;
    if (result) |res| {
        var r = res;
        len = r.text().len;
        r.deinit();
    } else |_| {}
    origin.stop();
    _ = try result;
    try t.expectEqual(@as(usize, 0), len);
    try t.expect(took < 1000);
}
