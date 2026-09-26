// Integration test for the `zio` io_backend (-Dio_backend=zio).
//
// Exercises the real request path — Server.listen() -> listenZio() ->
// workerLoop() -> handleConnection() -> router -> handler — hit by several
// real concurrent HTTP client connections. Asserts both correctness (every
// response is what the handler actually returned) and genuine concurrency
// (N slow requests complete in ~1 request's time, not N times that, which
// is the entire point of switching backends).
//
// Not wired into `zig build test` (has side effects: binds a real TCP
// listener). Run explicitly: `zig build test-zio-backend -Dio_backend=zio`.

const std = @import("std");
const spider = @import("spider");
const pacman = @import("pacman");

const CONCURRENCY: usize = 8;
const SLOW_MS: u64 = 150;

fn instantHandler(c: *spider.Ctx) !spider.Response {
    return c.text("instant", .{});
}

fn slowHandler(c: *spider.Ctx) !spider.Response {
    std.Io.sleep(c._io, .fromMilliseconds(SLOW_MS), .real) catch {};
    return c.text("slow-done", .{});
}

/// Renders a chain of `depth` nested components (C0 > C1 > ... > leaf).
fn renderChain(c: *spider.Ctx, depth: usize, self_recursive: bool) !spider.Response {
    var comps: std.StringHashMapUnmanaged([]const u8) = .{};
    if (self_recursive) {
        try comps.put(c.arena, "Loop", "<div><Loop /></div>");
    } else {
        for (0..depth) |i| {
            const name = try std.fmt.allocPrint(c.arena, "C{d}", .{i});
            const body = if (i + 1 < depth)
                try std.fmt.allocPrint(c.arena, "<div><C{d} /></div>", .{i + 1})
            else
                "leaf";
            try comps.put(c.arena, name, body);
        }
    }
    var tmpl = try spider.Template.init(c.arena, if (self_recursive) "<Loop />" else "<C0 />");
    tmpl.components = comps;
    const out = try tmpl.render(.{}, c.arena);
    return c.html(out, .{});
}

fn deepHandler(c: *spider.Ctx) !spider.Response {
    return renderChain(c, spider.template_max_component_depth, false);
}

fn recursiveHandler(c: *spider.Ctx) !spider.Response {
    return renderChain(c, 0, true);
}

fn testErrorHandler(c: *spider.Ctx, err: anyerror) !spider.Response {
    _ = c;
    return spider.Response{
        .status = .internal_server_error,
        .body = @errorName(err),
    };
}

/// Binds an ephemeral port (0), reads back what the OS actually assigned,
/// then releases it immediately. Not perfectly atomic — something else
/// could grab the same port in the gap before Server.listen() rebinds it —
/// but the window is microseconds, and Server.listen() already sets
/// .reuse_address = true, so a same-process rebind of a port released a
/// moment ago is effectively guaranteed to succeed in practice. This avoids
/// a hardcoded port number colliding with anything else on the machine.
fn reserveEphemeralPort(io: std.Io) !u16 {
    const probe_address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var probe = try probe_address.listen(io, .{ .reuse_address = true });
    defer probe.deinit(io);
    return probe.socket.address.getPort();
}

fn runServer(port: u16) void {
    var server = spider.app(.{});
    server
        .get("/instant", instantHandler, .{})
        .get("/slow", slowHandler, .{})
        .get("/deep", deepHandler, .{})
        .get("/recursive", recursiveHandler, .{})
        .onError(testErrorHandler)
        .listen(.{ .port = port, .host = "127.0.0.1" }) catch |err| {
        std.log.err("test server listen() failed: {s}", .{@errorName(err)});
    };
}

const FetchResult = struct {
    ok: bool = false,
    body_matches: bool = false,
};

fn fetchSlow(io: std.Io, gpa: std.mem.Allocator, port: u16, out: *FetchResult) std.Io.Cancelable!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const url = std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/slow", .{port}) catch return;

    var res = pacman.get(io, arena, url, .{ .timeout_ms = 5000 }) catch |err| {
        std.log.err("request failed: {s}", .{@errorName(err)});
        return;
    };
    defer res.deinit();

    out.ok = res.status == .ok;
    out.body_matches = std.mem.eql(u8, res.body_text, "slow-done");
}

test "zio backend: concurrent HTTP requests are handled correctly and concurrently" {
    const gpa = std.testing.allocator;

    var client_threaded: std.Io.Threaded = .init(gpa, .{});
    defer client_threaded.deinit();
    const client_io = client_threaded.io();

    const port = try reserveEphemeralPort(client_io);

    // listen() has no shutdown hook — its accept() loop only ever returns
    // on a genuine socket error, so there's no way to make this thread
    // return early without changing Server's public API (out of scope
    // here). A std.Io.Group.concurrent() + group.cancel() approach was
    // tried instead of this detach(): it does NOT work, and was confirmed
    // to hang under a hard timeout during development — the zio.Runtime
    // created inside listenZio() is its own independent Io, and
    // cancelation requested against client_io's Io.Threaded never reaches
    // the accept() call blocked inside that nested runtime.
    //
    // This detached thread keeps running until the test process exits.
    // That's fine for this file today (a single test, whose process exits
    // right after); the reserveEphemeralPort() call above is what actually
    // protects a second test added later — it gets its own OS-assigned
    // free port, so this leftover thread squatting on its own port doesn't
    // collide with anything.
    const server_thread = try std.Thread.spawn(.{}, runServer, .{port});
    server_thread.detach();

    // Give the listener a moment to bind before hammering it.
    std.Io.sleep(client_io, .fromMilliseconds(300), .real) catch {};

    // Sanity check: server is actually up and routing correctly before we
    // move on to the concurrency assertion.
    {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const url = try std.fmt.allocPrint(arena_state.allocator(), "http://127.0.0.1:{d}/instant", .{port});
        var res = try pacman.get(client_io, arena_state.allocator(), url, .{ .timeout_ms = 5000 });
        defer res.deinit();
        try std.testing.expectEqual(std.http.Status.ok, res.status);
        try std.testing.expectEqualStrings("instant", res.body_text);
    }

    var results: [CONCURRENCY]FetchResult = undefined;
    for (&results) |*r| r.* = .{};

    const start = std.Io.Clock.now(.real, client_io);

    var group: std.Io.Group = .init;
    for (0..CONCURRENCY) |i| {
        try group.concurrent(client_io, fetchSlow, .{ client_io, gpa, port, &results[i] });
    }
    try group.await(client_io);

    const elapsed = start.durationTo(std.Io.Clock.now(.real, client_io));
    const elapsed_ms = @divFloor(elapsed.nanoseconds, 1_000_000);

    for (results, 0..) |r, i| {
        if (!r.ok or !r.body_matches) {
            std.log.err("request {d} failed: ok={} body_matches={}", .{ i, r.ok, r.body_matches });
        }
        try std.testing.expect(r.ok);
        try std.testing.expect(r.body_matches);
    }

    std.debug.print(
        "\n[zio_backend_test] {d} concurrent /slow requests ({d}ms each) finished in {d}ms total\n",
        .{ CONCURRENCY, SLOW_MS, elapsed_ms },
    );

    // Sequential would be CONCURRENCY * SLOW_MS = 1200ms. Anything well
    // below that proves the requests actually overlapped instead of being
    // serialized behind a single accept()/handle() loop. Generous headroom
    // for CI/dev-machine scheduling jitter.
    try std.testing.expect(elapsed_ms < (CONCURRENCY * SLOW_MS) / 2);
}

test "zio backend: max-depth component nesting fits the coroutine stack, self-recursion is a 500 not a crash" {
    const gpa = std.testing.allocator;

    var client_threaded: std.Io.Threaded = .init(gpa, .{});
    defer client_threaded.deinit();
    const client_io = client_threaded.io();

    const port = try reserveEphemeralPort(client_io);
    const server_thread = try std.Thread.spawn(.{}, runServer, .{port});
    server_thread.detach();
    std.Io.sleep(client_io, .fromMilliseconds(300), .real) catch {};

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    {
        const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/deep", .{port});
        var res = try pacman.get(client_io, arena, url, .{ .timeout_ms = 5000 });
        defer res.deinit();
        try std.testing.expectEqual(std.http.Status.ok, res.status);
        try std.testing.expect(std.mem.indexOf(u8, res.body_text, "leaf") != null);
    }
    {
        // Before the depth limit this aborted the whole process with
        // "Coroutine stack overflow!" (the Orbitx BottomNavGatekeeper incident).
        const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/recursive", .{port});
        var res = try pacman.get(client_io, arena, url, .{ .timeout_ms = 5000 });
        defer res.deinit();
        try std.testing.expectEqual(std.http.Status.internal_server_error, res.status);
        try std.testing.expectEqualStrings("ComponentDepthExceeded", res.body_text);
    }
    {
        // Server is still alive and serving.
        const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/instant", .{port});
        var res = try pacman.get(client_io, arena, url, .{ .timeout_ms = 5000 });
        defer res.deinit();
        try std.testing.expectEqual(std.http.Status.ok, res.status);
    }
}
