//! Requests against the app itself, in a test.
//!
//!     fn run() !void {
//!         var server = spider.app(.{});
//!         defer server.deinit();
//!         try server.mountFeatures(features).listen(.{});
//!     }
//!
//!     test "the feed lists the posts" {
//!         const app = try spider.testing.start(run);
//!         var res = try app.get("/posts");
//!         defer res.deinit();
//!         try res.expectStatus(200);
//!         try res.expectContains("Latest posts");
//!     }
//!
//! `start` runs the function on a thread of its own, once per test binary,
//! and makes its `listen()` take a free port on 127.0.0.1. It is the real
//! server: middlewares, error handler, templates, cookies and all.
const std = @import("std");
const test_port = @import("port.zig");

/// A server started by `start`, ready to receive requests.
pub const App = struct {
    port: u16,
    /// Header lines sent with every request (see `with`).
    headers: []const []const u8 = &.{},

    /// The same app, sending `headers` with every request: a signed-in
    /// visitor is `app.with(&.{"Cookie: session=..."})`. The slice must
    /// outlive the requests made with it.
    pub fn with(self: App, headers: []const []const u8) App {
        return .{ .port = self.port, .headers = headers };
    }

    /// GETs `target` (the path, with its query string if any). Free the
    /// response with `deinit`.
    pub fn get(self: App, target: []const u8) !Response {
        return self.request(.{ .target = target });
    }

    /// POSTs `fields` (a struct of text fields) as an HTML form does.
    pub fn postForm(self: App, target: []const u8, fields: anytype) !Response {
        var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
        defer arena.deinit();
        return self.request(.{
            .method = "POST",
            .target = target,
            .headers = &.{"Content-Type: application/x-www-form-urlencoded"},
            .body = try formBody(arena.allocator(), fields),
        });
    }

    /// POSTs `json` (the text of a JSON document).
    pub fn postJson(self: App, target: []const u8, json: []const u8) !Response {
        return self.request(.{
            .method = "POST",
            .target = target,
            .headers = &.{"Content-Type: application/json"},
            .body = json,
        });
    }

    /// Any request: the method, extra header lines ("Cookie: a=b"), a body.
    /// Redirects are not followed: the answer is the 3xx itself.
    pub fn request(self: App, options: Request) !Response {
        var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const address = try std.Io.net.IpAddress.parse("127.0.0.1", self.port);
        var stream = try address.connect(io, .{ .mode = .stream });
        defer stream.close(io);

        var wbuf: [4096]u8 = undefined;
        var writer = stream.writer(io, &wbuf);
        const w = &writer.interface;
        try w.print("{s} {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n", .{ options.method, options.target });
        for (self.headers) |line| try w.print("{s}\r\n", .{line});
        for (options.headers) |line| try w.print("{s}\r\n", .{line});
        if (options.body) |body| {
            try w.print("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
        } else {
            try w.writeAll("\r\n");
        }
        try w.flush();

        var rbuf: [4096]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        const raw = try reader.interface.allocRemaining(a, .limited(16 * 1024 * 1024));

        const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.MalformedResponse;
        const head = raw[0..head_end];
        const space = std.mem.indexOfScalar(u8, head, ' ') orelse return error.MalformedResponse;
        if (head.len < space + 4) return error.MalformedResponse;
        return .{
            .status = try std.fmt.parseInt(u16, head[space + 1 .. space + 4], 10),
            .head = head,
            .body = raw[head_end + 4 ..],
            .method = try a.dupe(u8, options.method),
            .target = try a.dupe(u8, options.target),
            .arena = arena,
        };
    }
};

/// The options of `App.request`. Only `target` is required.
pub const Request = struct {
    method: []const u8 = "GET",
    target: []const u8,
    /// Extra header lines, each without its line ending: "Cookie: a=b".
    headers: []const []const u8 = &.{},
    body: ?[]const u8 = null,
};

/// What the server answered. Free it with `deinit`.
pub const Response = struct {
    status: u16,
    /// The status line and the headers, as sent.
    head: []const u8,
    body: []const u8,
    method: []const u8,
    target: []const u8,
    arena: std.heap.ArenaAllocator,

    /// Frees the response: `head`, `body` and what `header` and `cookie` returned.
    pub fn deinit(self: *Response) void {
        self.arena.deinit();
    }

    /// The first header named `name` (any letter case), or null.
    pub fn header(self: Response, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, self.head, "\r\n");
        _ = lines.next(); // the status line
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) {
                return std.mem.trim(u8, line[colon + 1 ..], " ");
            }
        }
        return null;
    }

    /// The value of the cookie `name` among the Set-Cookie headers (as sent,
    /// not decoded), or null.
    pub fn cookie(self: Response, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, self.head, "\r\n");
        _ = lines.next();
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(line[0..colon], "Set-Cookie")) continue;
            const pair = std.mem.trim(u8, line[colon + 1 ..], " ");
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (!std.mem.eql(u8, pair[0..eq], name)) continue;
            const end = std.mem.indexOfScalarPos(u8, pair, eq, ';') orelse pair.len;
            return pair[eq + 1 .. end];
        }
        return null;
    }

    /// Fails with `error.TestUnexpectedStatus` when the status is not
    /// `expected`, after printing the request and the start of the body.
    pub fn expectStatus(self: Response, expected: u16) !void {
        if (self.status == expected) return;
        self.report("expected status {d}, got {d}", .{ expected, self.status });
        return error.TestUnexpectedStatus;
    }

    /// Fails with `error.TestExpectedText` when the body does not contain `text`.
    pub fn expectContains(self: Response, text: []const u8) !void {
        if (std.mem.indexOf(u8, self.body, text) != null) return;
        self.report("the body does not contain: {s}", .{text});
        return error.TestExpectedText;
    }

    /// Fails with `error.TestUnexpectedText` when the body contains `text`.
    pub fn expectNotContains(self: Response, text: []const u8) !void {
        if (std.mem.indexOf(u8, self.body, text) == null) return;
        self.report("the body should not contain: {s}", .{text});
        return error.TestUnexpectedText;
    }

    /// Fails with `error.TestExpectedHeader` when the response has no header
    /// `name` or its value is not exactly `expected`.
    pub fn expectHeader(self: Response, name: []const u8, expected: []const u8) !void {
        const actual = self.header(name) orelse {
            self.report("no {s} header (expected {s})", .{ name, expected });
            return error.TestExpectedHeader;
        };
        if (std.mem.eql(u8, actual, expected)) return;
        self.report("{s}: expected {s}, got {s}", .{ name, expected, actual });
        return error.TestExpectedHeader;
    }

    /// A 3xx answer whose Location is `to`.
    pub fn expectRedirect(self: Response, to: []const u8) !void {
        if (self.status < 300 or self.status > 399) {
            self.report("expected a redirect to {s}, got status {d}", .{ to, self.status });
            return error.TestExpectedRedirect;
        }
        try self.expectHeader("Location", to);
    }

    fn report(self: Response, comptime fmt: []const u8, args: anytype) void {
        const max = 600;
        const shown = self.body[0..@min(self.body.len, max)];
        std.debug.print("\n{s} {s}: " ++ fmt ++ "\n--- body ({d} bytes) ---\n{s}{s}\n", .{ self.method, self.target } ++ args ++ .{
            self.body.len,
            shown,
            if (self.body.len > max) "\n[...]" else "",
        });
    }
};

/// Starts the app once and gives back where to send requests. `run` is what
/// main() does to serve: it builds the server and calls `listen()`, which
/// here takes a free port on 127.0.0.1 whatever port the app asks for.
/// Every test of the binary shares the one server; later calls return it.
pub fn start(comptime run: fn () anyerror!void) !App {
    const Once = struct {
        var mutex: std.atomic.Mutex = .unlocked;
        var app: ?App = null;
        var failure: ?anyerror = null;

        fn thread() void {
            run() catch |err| {
                failure = err;
            };
        }
    };
    while (!Once.mutex.tryLock()) std.atomic.spinLoopHint();
    defer Once.mutex.unlock();
    if (Once.app) |app| return app;

    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const port = try freePort(io);
    test_port.set(port);
    // listen() does not return while the server is up: the thread lives
    // until the test binary exits.
    const t = try std.Thread.spawn(.{}, Once.thread, .{});
    t.detach();

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var tries: usize = 0;
    while (tries < 500) : (tries += 1) {
        if (Once.failure) |err| return err;
        if (address.connect(io, .{ .mode = .stream })) |s| {
            s.close(io);
            Once.app = .{ .port = port };
            return Once.app.?;
        } else |_| {
            std.Io.sleep(io, .fromMilliseconds(20), .real) catch {};
        }
    }
    return error.ServerDidNotStart;
}

/// Asks the system for a free port and gives it back right away.
fn freePort(io: std.Io) !u16 {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var probe = try address.listen(io, .{ .reuse_address = true });
    defer probe.deinit(io);
    return probe.socket.address.getPort();
}

/// `fields` as application/x-www-form-urlencoded: text fields, numbers and
/// booleans; an optional field that is null is left out.
pub fn formBody(arena: std.mem.Allocator, fields: anytype) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const info = @typeInfo(@TypeOf(fields)).@"struct";
    inline for (info.field_names) |name| {
        const value = @field(fields, name);
        if (try fieldText(arena, value)) |text| {
            if (out.items.len > 0) try out.append(arena, '&');
            try appendEncoded(arena, &out, name);
            try out.append(arena, '=');
            try appendEncoded(arena, &out, text);
        }
    }
    return out.items;
}

fn fieldText(arena: std.mem.Allocator, value: anytype) !?[]const u8 {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .optional => if (value) |v| try fieldText(arena, v) else null,
        .bool => if (value) "true" else "false",
        .int, .comptime_int, .float, .comptime_float => try std.fmt.allocPrint(arena, "{d}", .{value}),
        else => @as([]const u8, value),
    };
}

fn appendEncoded(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-_.~", byte) != null) {
            try out.append(arena, byte);
        } else if (byte == ' ') {
            try out.append(arena, '+');
        } else {
            try out.print(arena, "%{X:0>2}", .{byte});
        }
    }
}

test "formBody: fields in order, encoded as a browser does" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const body = try formBody(arena.allocator(), .{
        .title = "Olá, mundo & co",
        .count = 3,
        .draft = true,
        .note = @as(?[]const u8, null),
    });
    try std.testing.expectEqualStrings("title=Ol%C3%A1%2C+mundo+%26+co&count=3&draft=true", body);
}

test "Response: header, cookie and the expectations" {
    var res: Response = .{
        .status = 303,
        .head = "HTTP/1.1 303 See Other\r\nLocation: /posts/5\r\nset-cookie: sid=abc; Path=/\r\nSet-Cookie: author=Ana%20R; Path=/; HttpOnly",
        .body = "<h1>Saved</h1>",
        .method = "POST",
        .target = "/posts/create",
        .arena = .init(std.testing.allocator),
    };
    defer res.deinit();
    try std.testing.expectEqualStrings("/posts/5", res.header("location").?);
    try std.testing.expectEqualStrings("abc", res.cookie("sid").?);
    try std.testing.expectEqualStrings("Ana%20R", res.cookie("author").?);
    try std.testing.expect(res.cookie("missing") == null);
    try res.expectStatus(303);
    try res.expectRedirect("/posts/5");
    try res.expectContains("Saved");
    try res.expectNotContains("Error");
    try res.expectHeader("Location", "/posts/5");
}
