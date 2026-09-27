//! `spider routes [--json | --check | --lock | --diff]`.
//!
//! The app lists its own routes: `zig build run` with SPIDER_ROUTES set
//! makes listen() print them and return. Without options that's the table
//! (SPIDER_ROUTES=1, passed straight through). The options read the JSON
//! listing (SPIDER_ROUTES=json) instead:
//!
//!   --json   print it (one line)
//!   --check  exit 1 when the app has auth and a route declares no access
//!            ("-"): with auth, "-" means any logged-in user
//!   --lock   write routes.lock (method, path, access, flags per line)
//!   --diff   compare with routes.lock: exit 1 and print what changed
//!
//! Everything but the process spawning is pure and unit-tested below.

const std = @import("std");

pub const Mode = enum { table, json, check, lock, diff };

pub const lock_file = "routes.lock";

pub fn parseMode(args: []const []const u8, bad: *[]const u8) error{ UnknownOption, TooManyOptions }!Mode {
    var mode: Mode = .table;
    for (args) |a| {
        const m: Mode = if (std.mem.eql(u8, a, "--json"))
            .json
        else if (std.mem.eql(u8, a, "--check"))
            .check
        else if (std.mem.eql(u8, a, "--lock"))
            .lock
        else if (std.mem.eql(u8, a, "--diff"))
            .diff
        else {
            bad.* = a;
            return error.UnknownOption;
        };
        if (mode != .table) {
            bad.* = a;
            return error.TooManyOptions;
        }
        mode = m;
    }
    return mode;
}

pub const RouteJson = struct {
    method: []const u8,
    path: []const u8,
    access: []const u8,
    public: bool = false,
    authenticated: bool = false,
    roles: []const []const u8 = &.{},
    org_roles: []const []const u8 = &.{},
    quiet_log: bool = false,
    allow_http: bool = false,
};

pub const Listing = struct {
    auth: bool,
    routes: []const RouteJson,
    jobs_ms: []const u64 = &.{},
    duplicates: usize = 0,
};

/// The JSON line in the app's stdout (other lines, e.g. warnings the app
/// prints before listen(), are skipped).
pub fn findJsonLine(stdout: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "{\"auth\":")) found = line;
    }
    return found;
}

pub fn parseListing(arena: std.mem.Allocator, line: []const u8) !Listing {
    return std.json.parseFromSliceLeaky(Listing, arena, line, .{ .ignore_unknown_fields = true });
}

/// One line per route for routes.lock: "GET /posts roles:editor quiet_log".
pub fn lockLine(arena: std.mem.Allocator, r: RouteJson) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s} {s} {s}{s}{s}", .{
        r.method,
        r.path,
        r.access,
        if (r.quiet_log) " quiet_log" else "",
        if (r.allow_http) " allow_http" else "",
    });
}

pub const lock_header =
    \\# routes.lock — written by `spider routes --lock`; checked by `spider routes --diff`.
    \\# One route per line: method, path, access (public, roles:, org:, or - for
    \\# nothing declared), flags. Commit it: a diff here is an access change.
    \\
;

pub fn renderLock(arena: std.mem.Allocator, l: Listing) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, lock_header);
    for (l.routes) |r| {
        try out.appendSlice(arena, try lockLine(arena, r));
        try out.append(arena, '\n');
    }
    return out.items;
}

/// --check: routes with no declared access, when the app has auth.
pub fn undeclared(arena: std.mem.Allocator, l: Listing) ![]const RouteJson {
    var out: std.ArrayListUnmanaged(RouteJson) = .empty;
    if (!l.auth) return out.items;
    for (l.routes) |r| {
        // Spider's development-only live reload (as in the server's own check).
        if (std.mem.eql(u8, r.path, "/_spider/reload")) continue;
        if (std.mem.eql(u8, r.access, "-")) try out.append(arena, r);
    }
    return out.items;
}

pub const Diff = struct {
    /// In routes.lock, not in the app any more (or changed).
    removed: []const []const u8,
    /// In the app, not in routes.lock (new or changed).
    added: []const []const u8,
};

fn routeLines(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        try out.append(arena, line);
    }
    return out.items;
}

fn has(list: []const []const u8, s: []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, s)) return true;
    return false;
}

pub fn diff(arena: std.mem.Allocator, lock_text: []const u8, current_text: []const u8) !Diff {
    const old = try routeLines(arena, lock_text);
    const new = try routeLines(arena, current_text);
    var removed: std.ArrayListUnmanaged([]const u8) = .empty;
    var added: std.ArrayListUnmanaged([]const u8) = .empty;
    for (old) |l| if (!has(new, l)) try removed.append(arena, l);
    for (new) |l| if (!has(old, l)) try added.append(arena, l);
    return .{ .removed = removed.items, .added = added.items };
}

// ── Running the app ─────────────────────────────────────────────────────

fn say(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch {};
}

pub fn run(io: std.Io, arena: std.mem.Allocator, environ_map: *std.process.Environ.Map, mode: Mode) !u8 {
    if (mode == .table) {
        try environ_map.put("SPIDER_ROUTES", "1");
        var child = try std.process.spawn(io, .{ .argv = &.{ "zig", "build", "run" }, .environ_map = environ_map });
        return switch (try child.wait(io)) {
            .exited => |code| code,
            else => 1,
        };
    }

    try environ_map.put("SPIDER_ROUTES", "json");
    const res = try std.process.run(arena, io, .{ .argv = &.{ "zig", "build", "run" }, .environ_map = environ_map });
    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    const line = findJsonLine(res.stdout) orelse {
        std.debug.print("{s}{s}error: the app printed no route listing (`zig build run` with SPIDER_ROUTES=json){s}\n", .{
            res.stderr, res.stdout,
            if (ok) "" else " — it failed, see above",
        });
        return 1;
    };
    const listing = parseListing(arena, line) catch |err| {
        std.debug.print("error: unreadable route listing ({s}): {s}\n", .{ @errorName(err), line });
        return 1;
    };

    switch (mode) {
        .table => unreachable,
        .json => say(io, "{s}\n", .{line}),
        .check => {
            if (!listing.auth) {
                say(io, "no auth middleware found (Spider's providers, or one marked with spider.markAuthMiddleware): nothing to check\n", .{});
                return 0;
            }
            const bad = try undeclared(arena, listing);
            if (bad.len == 0) {
                say(io, "ok: all {d} routes declare their access\n", .{listing.routes.len});
                return 0;
            }
            std.debug.print("{d} route(s) declare no access; with auth, any logged-in user may call them:\n", .{bad.len});
            for (bad) |r| std.debug.print("  {s} {s}\n", .{ r.method, r.path });
            std.debug.print("fix: .roles / .org_roles / .authenticated / .public in the route's config, or defaults() in its group\n", .{});
            return 1;
        },
        .lock => {
            const text = try renderLock(arena, listing);
            const file = try std.Io.Dir.cwd().createFile(io, lock_file, .{});
            defer file.close(io);
            var buf: [4096]u8 = undefined;
            var w = file.writer(io, &buf);
            try w.interface.writeAll(text);
            try w.interface.flush();
            say(io, "wrote {s} ({d} routes)\n", .{ lock_file, listing.routes.len });
        },
        .diff => {
            const lock_text = std.Io.Dir.cwd().readFileAlloc(io, lock_file, arena, .limited(4 * 1024 * 1024)) catch |err| {
                std.debug.print("error: can't read {s} ({s}); create it with `spider routes --lock`\n", .{ lock_file, @errorName(err) });
                return 2;
            };
            const d = try diff(arena, lock_text, try renderLock(arena, listing));
            if (d.removed.len == 0 and d.added.len == 0) {
                say(io, "routes match {s} ({d} routes)\n", .{ lock_file, listing.routes.len });
                return 0;
            }
            std.debug.print("routes differ from {s}:\n", .{lock_file});
            for (d.removed) |l| std.debug.print("- {s}\n", .{l});
            for (d.added) |l| std.debug.print("+ {s}\n", .{l});
            std.debug.print("if intended, review and update it: spider routes --lock\n", .{});
            return 1;
        },
    }
    return 0;
}

const t = std.testing;

test "parseMode: none, each option, unknown, two at once" {
    var bad: []const u8 = "";
    try t.expectEqual(Mode.table, try parseMode(&.{}, &bad));
    try t.expectEqual(Mode.json, try parseMode(&.{"--json"}, &bad));
    try t.expectEqual(Mode.check, try parseMode(&.{"--check"}, &bad));
    try t.expectEqual(Mode.lock, try parseMode(&.{"--lock"}, &bad));
    try t.expectEqual(Mode.diff, try parseMode(&.{"--diff"}, &bad));
    try t.expectError(error.UnknownOption, parseMode(&.{"--all"}, &bad));
    try t.expectEqualStrings("--all", bad);
    try t.expectError(error.TooManyOptions, parseMode(&.{ "--lock", "--diff" }, &bad));
}

const sample_stdout =
    \\[spider] WARNING: No templates found in "./src".
    \\{"auth":true,"routes":[{"method":"GET","path":"/","access":"public","public":true,"roles":[],"org_roles":[],"quiet_log":false,"allow_http":false},{"method":"GET","path":"/posts","access":"-","public":false,"roles":[],"org_roles":[],"quiet_log":false,"allow_http":false},{"method":"GET","path":"/up","access":"public","public":true,"roles":[],"org_roles":[],"quiet_log":true,"allow_http":false},{"method":"POST","path":"/posts/:id/delete","access":"roles:admin","public":false,"roles":["admin"],"org_roles":[],"quiet_log":false,"allow_http":true}],"jobs_ms":[],"duplicates":0}
    \\
;

test "findJsonLine + parseListing: the listing among other stdout lines" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const l = try parseListing(arena.allocator(), findJsonLine(sample_stdout).?);
    try t.expect(l.auth);
    try t.expectEqual(@as(usize, 4), l.routes.len);
    try t.expectEqualStrings("roles:admin", l.routes[3].access);
    try t.expect(findJsonLine("no listing here\n") == null);
}

test "undeclared: routes with \"-\" only when the app has auth" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var l = try parseListing(arena.allocator(), findJsonLine(sample_stdout).?);
    const bad = try undeclared(arena.allocator(), l);
    try t.expectEqual(@as(usize, 1), bad.len);
    try t.expectEqualStrings("/posts", bad[0].path);
    l.auth = false;
    try t.expectEqual(@as(usize, 0), (try undeclared(arena.allocator(), l)).len);
}

test "renderLock + diff: identical, then an access change and a new route" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try parseListing(a, findJsonLine(sample_stdout).?);
    const lock = try renderLock(a, l);
    try t.expect(std.mem.startsWith(u8, lock, "# routes.lock"));
    try t.expect(std.mem.indexOf(u8, lock, "\nGET /up public quiet_log\n") != null);
    try t.expect(std.mem.indexOf(u8, lock, "\nPOST /posts/:id/delete roles:admin allow_http\n") != null);

    const same = try diff(a, lock, lock);
    try t.expectEqual(@as(usize, 0), same.removed.len + same.added.len);

    const changed = try std.mem.replaceOwned(u8, a, lock, "GET /posts -\n", "GET /posts roles:editor\nGET /posts/export roles:editor\n");
    const d = try diff(a, lock, changed);
    try t.expectEqual(@as(usize, 1), d.removed.len);
    try t.expectEqualStrings("GET /posts -", d.removed[0]);
    try t.expectEqual(@as(usize, 2), d.added.len);
    try t.expectEqualStrings("GET /posts roles:editor", d.added[0]);
}

test "undeclared: Spider's development-only /_spider/reload is not flagged" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const l = try parseListing(arena.allocator(),
        \\{"auth":true,"routes":[{"method":"GET","path":"/_spider/reload","access":"-"},{"method":"GET","path":"/x","access":"-"}]}
    );
    const bad = try undeclared(arena.allocator(), l);
    try t.expectEqual(@as(usize, 1), bad.len);
    try t.expectEqualStrings("/x", bad[0].path);
}
