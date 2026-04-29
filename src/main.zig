const std = @import("std");
const spider = @import("spider");
const Response = spider.Response;

var request_count: u64 = 0;

fn rootHandler(c: *spider.Ctx) !Response {
    request_count += 1;
    return c.json(.{ .message = "Hello from Spider!", .status = "OK", .requests = request_count }, .{});
}

fn healthHandler(c: *spider.Ctx) !Response {
    return c.json(.{ .status = "healthy", .requests_served = request_count }, .{});
}

fn echoHandler(c: *spider.Ctx) !Response {
    return c.text("Echo response: Simple and fast!", .{});
}

fn userHandler(c: *spider.Ctx) !Response {
    const path = c.getPath();
    const user_id = if (std.mem.startsWith(u8, path, "/users/"))
        path["/users/".len..]
    else
        "unknown";
    return c.json(.{ .user_id = user_id, .name = "John Doe", .email = "john@example.com" }, .{});
}

fn htmlHandler(c: *spider.Ctx) !Response {
    return c.render("Hello {{ name }}!", .{ .name = "Spider" }, .{});
}

fn arenaHandler(c: *spider.Ctx) !Response {
    const msg = try std.fmt.allocPrint(c.arena, "Request arena working! Thread: {d}", .{std.Thread.getCurrentId()});
    return c.json(.{ .message = msg }, .{});
}

fn createdHandler(c: *spider.Ctx) !Response {
    return c.json(.{ .id = 1, .created = true }, .{ .status = .created });
}

fn headersHandler(c: *spider.Ctx) !Response {
    return c.json(.{ .ok = true }, .{
        .headers = &.{
            .{ "X-Powered-By", "Spider" },
            .{ "X-Version", "0.3.0" },
        },
    });
}

fn queryHandler(c: *spider.Ctx) !Response {
    const name = c.query("name") orelse "World";
    return c.json(.{ .hello = name }, .{});
}

fn headerHandler(c: *spider.Ctx) !Response {
    const ua = c.header("User-Agent") orelse "unknown";
    return c.json(.{ .user_agent = ua }, .{});
}

fn redirectHandler(c: *spider.Ctx) !Response {
    return c.redirect("/");
}

fn echoBodyHandler(c: *spider.Ctx) !Response {
    const raw = c.getBody() orelse return c.text("no body", .{});
    return c.text(raw, .{});
}

const CreateUser = struct {
    name: []const u8,
    email: []const u8,
};

fn createUserHandler(c: *spider.Ctx) !Response {
    const user = try c.bodyJson(CreateUser);
    return c.json(.{
        .created = true,
        .name = user.name,
        .email = user.email,
    }, .{ .status = .created });
}

pub fn main() void {
    var server = spider.app();
    defer server.deinit();
    server
        .get("/", rootHandler)
        .get("/health", healthHandler)
        .get("/echo", echoHandler)
        .get("/users/:id", userHandler)
        .get("/html", htmlHandler)
        .get("/arena", arenaHandler)
        .get("/created", createdHandler)
        .get("/headers", headersHandler)
        .get("/query", queryHandler)
        .get("/useragent", headerHandler)
        .get("/redirect", redirectHandler)
        .post("/echo-body", echoBodyHandler)
        .post("/users", createUserHandler)
        .listen(3000) catch |err| {
        std.debug.print("Server error: {}\n", .{err});
    };
}
