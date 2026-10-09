const spider = @import("spider");
const controller = @import("controller.zig");

/// Routes of the login. src/main.zig mounts them with
/// `server.mountFeatures(features)`.
///
/// The pages to sign in and to create an account are `.public`: everyone
/// reaches them. The rest needs a session.
pub fn build() spider.Group {
    var g = spider.Group.init("/auth");
    _ = g
        .get("/login", controller.loginForm, .{ .public = true })
        .post("/login", controller.login, .{ .public = true })
        .get("/register", controller.registerForm, .{ .public = true })
        .post("/register", controller.register, .{ .public = true })
        .get("/account", controller.account, .{ .authenticated = true })
        .post("/logout", controller.logout, .{ .authenticated = true });
    return g;
}
