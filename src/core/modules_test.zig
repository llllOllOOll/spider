// Server.mountModules, checkModules, migrateModules and listen()'s gate,
// on a real Server without a network (see module.zig for the rules
// themselves, tested there).

const std = @import("std");
const app_mod = @import("app.zig");
const Server = app_mod.Server;
const module = @import("module.zig").module;
const Check = @import("module.zig").Check;
const Ctx = @import("context.zig").Ctx;
const Response = @import("context.zig").Response;
const Group = @import("../routing/group.zig").Group;
const Hub = @import("../ws/hub.zig").Hub;

const NoDeco = struct {};
// Built with -Dpg=true, the database is there but never opened in these tests.
const with_pg = @import("spider_build_options").pg;
const migrations_line = if (with_pg)
    "  with_migrations: ships database migrations, but the database is not open: call spider.pg.init(...) before listen()\n"
else
    "  with_migrations: ships database migrations, but the app is built without PostgreSQL (build Spider with -Dpg=true)\n";

var events: [16][]const u8 = undefined;
var event_count: usize = 0;

fn record(e: []const u8) void {
    events[event_count] = e;
    event_count += 1;
}

fn recorded() []const []const u8 {
    return events[0..event_count];
}

fn ok(c: *Ctx) anyerror!Response {
    return c.text("ok", .{});
}

fn tick(_: *Hub) void {}

// `app_notices` requires `notify`, and is listed first: it must start after.
const app_notices = struct {
    pub const spider_module = module(.{ .name = "app_notices", .version = "1.0.0", .spider = ">=0.10.0 <1.0.0", .requires = .{"notify"} });
    pub fn boot(_: app_mod.Boot) !void {
        record("boot app_notices");
    }
    pub fn shutdown(_: app_mod.Boot) void {
        record("shutdown app_notices");
    }
};

const notify = struct {
    pub const spider_module = module(.{ .name = "notify", .version = "0.2.0", .spider = ">=0.10.0 <1.0.0" });
    pub const routes = struct {
        pub fn build() Group {
            var g = Group.init("/notify");
            _ = g.get("", ok, .{ .public = true });
            return g;
        }
        // Not a route builder: not mounted, and not an error.
        pub fn helper(x: u8) u8 {
            return x;
        }
    };
    pub const jobs = .{app_mod.every(30_000, tick)};
    pub fn check(_: *Check) !void {
        record("check notify");
    }
    pub fn boot(_: app_mod.Boot) !void {
        record("boot notify");
    }
    pub fn shutdown(_: app_mod.Boot) void {
        record("shutdown notify");
    }
};

const feats = struct {
    pub const reservations = struct {
        pub fn boot(_: app_mod.Boot) !void {
            record("boot feature");
        }
    };
    // A module declared among the features: mountFeatures leaves it to
    // mountModules instead of mounting it twice.
    pub const notify_again = notify;
};

fn runBoots(s: *Server(NoDeco)) !void {
    for (s.module_boot_hooks.items) |h| try h(.{ .allocator = std.testing.allocator, .io = undefined });
    for (s.boot_hooks.items) |h| try h(.{ .allocator = std.testing.allocator, .io = undefined });
}

test "mountModules: dependency order, routes, jobs, modules before features, shutdown in reverse" {
    event_count = 0;
    {
        var s = Server(NoDeco).init();
        defer s.deinit();
        _ = s.mountModules(.{ app_notices, notify }).mountFeatures(feats);

        try std.testing.expectEqual(@as(usize, 2), s.module_entries.items.len);
        try std.testing.expectEqualStrings("notify", s.module_entries.items[0].manifest.name);
        try std.testing.expectEqualStrings("app_notices", s.module_entries.items[1].manifest.name);

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expect((try s.router.match(.GET, "/notify", arena.allocator())) != null);
        // the module's job once: mountFeatures skipped notify_again
        try std.testing.expectEqual(@as(usize, 1), s.interval_threads.items.len);
        try std.testing.expectEqual(@as(u64, 30_000), s.interval_threads.items[0].ms);
        try std.testing.expectEqual(@as(usize, 1), s.boot_hooks.items.len);

        try runBoots(&s);
    }
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{
        "boot notify",
        "boot app_notices",
        "boot feature",
        "shutdown app_notices",
        "shutdown notify",
    }), recorded());
}

test "checkModules: a ready set runs every module's check, in start order" {
    event_count = 0;
    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.mountModules(.{ app_notices, notify });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const report = s.checkModules(arena.allocator(), threaded.io());
    try std.testing.expect(report.ok());
    try std.testing.expectEqual(@as(usize, 2), report.checked);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"check notify"}), recorded());
}

const needs_key = struct {
    pub const spider_module = module(.{
        .name = "needs_key",
        .version = "1.0.0",
        .spider = ">=0.10.0 <1.0.0",
        .env = .{ .required = .{"SPIDER_TEST_MODULE_KEY_NEVER_SET"} },
    });
    pub fn check(_: *Check) !void {
        record("check needs_key"); // skipped: Spider's own check failed first
    }
};

const fails_check = struct {
    pub const spider_module = module(.{ .name = "fails_check", .version = "1.0.0", .spider = ">=0.10.0 <1.0.0" });
    pub fn check(c: *Check) !void {
        c.fail("the provider key is missing", .{});
        return error.ProviderUnreachable;
    }
};

const with_migrations = struct {
    pub const spider_module = module(.{
        .name = "with_migrations",
        .version = "1.0.0",
        .spider = ">=0.10.0 <1.0.0",
        .migrations = .{.{ .name = "0001_init", .sql = "CREATE TABLE t (id int)" }},
    });
};

test "checkModules: every problem of every module, then listen() refuses before binding" {
    event_count = 0;
    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.mountModules(.{ needs_key, fails_check, with_migrations });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const report = s.checkModules(arena.allocator(), threaded.io());
    try std.testing.expect(!report.ok());

    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try report.write(&w);
    try std.testing.expectEqualStrings(
        \\spider: 3 module(s) not ready, refusing to start
        \\  needs_key: SPIDER_TEST_MODULE_KEY_NEVER_SET is required but not set
        \\  fails_check: the provider key is missing
        \\  fails_check: check() failed: error.ProviderUnreachable
        \\
    ++ migrations_line, w.buffered());
    try std.testing.expectEqual(@as(usize, 0), event_count);

    // Port 1 can't be bound by a test: reaching bind() would fail differently.
    try std.testing.expectError(error.ModulesNotReady, s.listen(.{ .port = 1, .host = "127.0.0.1" }));
}

test "mountModules: a second call is refused by listen()" {
    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.mountModules(.{notify}).mountModules(.{app_notices_alone});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const report = s.checkModules(arena.allocator(), threaded.io());
    try std.testing.expect(!report.ok());
    try std.testing.expectEqualStrings("spider", report.problems.items[0].module);
    try std.testing.expectError(error.ModulesNotReady, s.listen(.{ .port = 1, .host = "127.0.0.1" }));
}

const app_notices_alone = struct {
    pub const spider_module = module(.{ .name = "app_notices_alone", .version = "1.0.0", .spider = ">=0.10.0 <1.0.0" });
};

test "migrateModules: without PostgreSQL error.NoDatabase; before spider.pg.init error.DatabaseNotInitialized" {
    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.mountModules(.{with_migrations});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(if (with_pg) error.DatabaseNotInitialized else error.NoDatabase, s.migrateModules(arena.allocator()));
}

test "migrateModules: modules without migrations need no database" {
    var s = Server(NoDeco).init();
    defer s.deinit();
    _ = s.mountModules(.{ notify, app_notices });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), try s.migrateModules(arena.allocator()));
}

test "no modules: nothing checked, listen() goes on as before" {
    var s = Server(NoDeco).init();
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const report = s.checkModules(arena.allocator(), threaded.io());
    try std.testing.expect(report.ok());
    try std.testing.expectEqual(@as(usize, 0), report.checked);
}
