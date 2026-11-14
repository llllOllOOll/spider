const spider = @import("spider");
const routes = @import("routes.zig");

// The access contract of the books routes (see spider routes / routes.zig).
test "books routes: method, path and access" {
    try spider.testing.expectRoutes(routes.build(), &.{
        .{ "GET", "/", "public" },
        .{ "GET", "/books/:id", "public" },
        .{ "GET", "/about", "public" },
        .{ "GET", "/api/health", "public" },
        .{ "GET", "/api/books", "public" },
    });
}
