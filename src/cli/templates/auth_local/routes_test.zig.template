const spider = @import("spider");
const routes = @import("routes.zig");

// The access contract of the login routes: what `spider routes` prints for
// them. Changing a route, or who may call it, fails `zig build test` until
// this table changes too.
test "auth routes: method, path and access" {
    try spider.testing.expectRoutes(routes.build(), &.{
        .{ "GET", "/auth/login", "public" },
        .{ "POST", "/auth/login", "public" },
        .{ "GET", "/auth/register", "public" },
        .{ "POST", "/auth/register", "public" },
        .{ "GET", "/auth/account", "authenticated" },
        .{ "POST", "/auth/logout", "authenticated" },
    });
}
