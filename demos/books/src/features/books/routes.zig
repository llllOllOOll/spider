const spider = @import("spider");
const controller = @import("controller.zig");

/// Mounted by `server.mountFeatures(features)` in src/main.zig. Every route
/// is public: the demo has no login.
pub fn build() spider.Group {
    var g = spider.Group.init("");
    _ = g.get("/", controller.index, .{ .public = true })
        .get("/books/:id", controller.show, .{ .public = true })
        .get("/about", controller.about, .{ .public = true })
        .get("/api/health", controller.health, .{ .public = true })
        .get("/api/books", controller.apiBooks, .{ .public = true });
    return g;
}
