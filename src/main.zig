const std = @import("std");
const spider = @import("spider");

// Global metrics
var request_count: u64 = 0;

// Handlers for different routes
fn rootHandler(c: *spider.Ctx) !void {
    request_count += 1;
    return c.json(.{ .message = "Hello from Spider!", .status = "OK", .requests = request_count });
}

fn healthHandler(c: *spider.Ctx) !void {
    return c.json(.{ .status = "healthy", .requests_served = request_count });
}

fn echoHandler(c: *spider.Ctx) !void {
    return c.text("Echo response: Simple and fast!");
}

fn userHandler(c: *spider.Ctx) !void {
    const path = c.getPath();
    // Simulate URL ID extraction
    const user_id = if (std.mem.startsWith(u8, path, "/users/"))
        path["/users/".len..]
    else
        "unknown";

    return c.json(.{ .user_id = user_id, .name = "John Doe", .email = "john@example.com" });
}

pub fn main() void {
    var server = spider.app();
    defer server.deinit();
    server
        .get("/", rootHandler)
        .get("/health", healthHandler)
        .get("/echo", echoHandler)
        .get("/users/:id", userHandler)
        .listen(3000) catch |err| {
        std.debug.print("Server error: {}\n", .{err});
    };
}
