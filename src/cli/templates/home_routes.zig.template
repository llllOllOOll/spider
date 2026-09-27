const spider = @import("spider");
const controller = @import("controller.zig");

/// Mounted by `server.mountFeatures(features)` in src/main.zig. `.public`:
/// the home page stays open once the app has a login (spider g auth).
pub fn build() spider.Group {
    var g = spider.Group.init("");
    _ = g.get("/", controller.index, .{ .public = true });
    return g;
}
