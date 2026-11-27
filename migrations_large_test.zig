//! A long list of real migration files (400 of them, 30 statements each,
//! generated and embedded by build.zig the way spider.addMigrations embeds
//! an app's): `Server.migrations` and `spider.module` check every one at
//! compile time, and must take a list of any length and size.

const std = @import("std");
const spider = @import("spider");
const large = @import("large_migrations");

const big = struct {
    pub const spider_module = spider.module(.{
        .name = "big",
        .version = "1.0.0",
        .spider = ">=0.10.0 <1.0.0",
        .migrations = large.all,
    });
};

test "migrations: a long list of embedded files passes the compile-time checks" {
    var s = spider.Server(struct {}).init();
    defer s.deinit();
    _ = s.mountModules(.{big}).migrations(large.all);
    try std.testing.expectEqual(@as(usize, 400), large.all.len);
    try std.testing.expect(std.mem.startsWith(u8, spider.migration.upSection(large.all[399].sql), "ALTER TABLE table_399 "));
}
