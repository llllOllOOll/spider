const std = @import("std");
const spider = @import("spider");
const features = @import("features");
// const db = spider.pg;

pub const spider_templates = @import("embedded_templates.zig").EmbeddedTemplates;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    _ = allocator;
    _ = io;

    // Uncomment to enable PostgreSQL (reads from .env automatically)
    // try db.init(allocator, io, .{});
    // defer db.deinit();

    var server = spider.app(.{});
    defer server.deinit();

    // Routes live with their feature (src/features/<name>/routes.zig);
    // mountFeatures registers every feature listed in src/features/mod.zig.
    // `spider routes` prints what got registered.
    server
        .use(spider.logger)
        .mountFeatures(features)
        .onError(spider.errorHandler(.{ .template_not_found_is_404 = true }))
        .listen(.{ .port = 3000, .host = "0.0.0.0" }) catch |err| return err;
}

// Routes in routes.zig with declared access, ui-* classes, icons from the
// active sets, features registered: `spider check` prints the same report.
test "the app follows Spider's conventions" {
    try @import("spider").testing.expectConventions();
}

test "every file with tests is part of this test binary" {
    try @import("spider").testing.expectAllTestsDiscovered(@import("test_manifest"));
}
