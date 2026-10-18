// End-to-end tests for modules: a real server with mounted modules starts
// them in dependency order before the features and serves their routes; a
// server whose module is not ready never listens.

const std = @import("std");
const spider = @import("spider");

var boot_log: [128]u8 = undefined;
var boot_len: usize = 0;

fn logBoot(name: []const u8) void {
    if (boot_len > 0) {
        boot_log[boot_len] = ',';
        boot_len += 1;
    }
    @memcpy(boot_log[boot_len..][0..name.len], name);
    boot_len += name.len;
}

fn bootOrder(c: *spider.Ctx) !spider.Response {
    return c.text(boot_log[0..boot_len], .{});
}

// Mounted first but requires `store`: starts second.
const greeter = struct {
    pub const spider_module = spider.module(.{ .name = "greeter", .version = "1.0.0", .spider = ">=0.10.0 <1.0.0", .requires = .{"store"} });
    pub const routes = struct {
        pub fn build() spider.Group {
            var g = spider.Group.init("/greeter");
            _ = g.get("/boot-order", bootOrder, .{ .public = true });
            return g;
        }
    };
    pub fn boot(_: spider.Boot) !void {
        logBoot("greeter");
    }
};

const store = struct {
    pub const spider_module = spider.module(.{ .name = "store", .version = "1.0.0", .spider = ">=0.10.0 <1.0.0" });
    pub fn check(c: *spider.Check) !void {
        // A module's check sees the environment, like spider.env.
        if (c.env("PATH") == null) c.fail("PATH is not set", .{});
    }
    pub fn boot(_: spider.Boot) !void {
        logBoot("store");
    }
};

const features = struct {
    pub const home = struct {
        pub fn boot(_: spider.Boot) !void {
            logBoot("feature");
        }
    };
};

fn runReady() !void {
    var server = spider.app(.{});
    defer server.deinit();
    try server.mountModules(.{ greeter, store }).mountFeatures(features).listen(.{});
}

const broken = struct {
    pub const spider_module = spider.module(.{
        .name = "broken",
        .version = "1.0.0",
        .spider = ">=0.10.0 <1.0.0",
        .env = .{ .required = .{"SPIDER_E2E_MODULE_KEY_NEVER_SET"} },
    });
    pub fn boot(_: spider.Boot) !void {
        logBoot("broken"); // never: the check fails first
    }
};

fn runBroken() !void {
    var server = spider.app(.{});
    defer server.deinit();
    try server.mountModules(.{broken}).listen(.{});
}

test "modules: started in dependency order before the features, routes served" {
    const app = try spider.testing.start(runReady);
    var res = try app.get("/greeter/boot-order");
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("store,greeter,feature", res.body);
}

test "modules: a module that is not ready keeps the server from listening" {
    try std.testing.expectError(error.ModulesNotReady, spider.testing.start(runBroken));
}

// e2e/fixtures/app_migrations, embedded by spider.addMigrations (build.zig).
const fixture_migrations = @import("test_app_migrations");

test "addMigrations: every .sql file of the folder, named after it, in order; the server takes them" {
    try std.testing.expectEqual(@as(usize, 2), fixture_migrations.all.len);
    try std.testing.expectEqualStrings("1700000000_create_items", fixture_migrations.all[0].name);
    try std.testing.expect(std.mem.indexOf(u8, fixture_migrations.all[0].sql, "CREATE TABLE fixture_items") != null);
    try std.testing.expectEqualStrings("1700000100_add_name", fixture_migrations.all[1].name);

    try std.testing.expectError(error.ModulesNotReady, spider.testing.start(runWithMigrations));
}

// Built without PostgreSQL: the app's migrations cannot be applied, so the
// server does not start.
fn runWithMigrations() !void {
    var server = spider.app(.{});
    defer server.deinit();
    try server.migrations(fixture_migrations.all).listen(.{});
}
