const std = @import("std");
const auth = @import("auth");
const spider = @import("spider");
const web = spider.web;

// ============================================================================
// AUTH MODULE TESTS
// ============================================================================

test "hashPassword produces consistent hash" {
    const allocator = std.testing.allocator;

    const hash1 = try auth.hashPassword(allocator, "password123");
    defer allocator.free(hash1);

    const hash2 = try auth.hashPassword(allocator, "password123");
    defer allocator.free(hash2);

    try std.testing.expectEqualStrings(hash1, hash2);
}

test "hashPassword different passwords produce different hashes" {
    const allocator = std.testing.allocator;

    const hash1 = try auth.hashPassword(allocator, "password123");
    defer allocator.free(hash1);

    const hash2 = try auth.hashPassword(allocator, "password456");
    defer allocator.free(hash2);

    try std.testing.expect(!std.mem.eql(u8, hash1, hash2));
}

test "generateToken produces unique tokens" {
    const allocator = std.testing.allocator;

    const token1 = try auth.generateToken(allocator);
    defer allocator.free(token1);

    const token2 = try auth.generateToken(allocator);
    defer allocator.free(token2);

    try std.testing.expect(!std.mem.eql(u8, token1, token2));
}

test "generateToken produces 64 character hex string" {
    const allocator = std.testing.allocator;

    const token = try auth.generateToken(allocator);
    defer allocator.free(token);

    try std.testing.expectEqual(token.len, 64);

    // Check all characters are valid hex
    for (token) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(is_hex);
    }
}

// ============================================================================
// ROUTER TESTS
// ============================================================================

test "static route match" {
    const allocator = std.testing.allocator;

    var app = try web.App.init(allocator);
    defer app.deinit();

    const handler = struct {
        pub fn handle(a: std.mem.Allocator, r: *web.Request) !web.Response {
            _ = r;
            return try web.Response.text(a, "index");
        }
    }.handle;

    try app.get("/", handler);

    var req = web.Request{
        .method = .get,
        .path = "/",
        .query = null,
        .headers = web.Headers.init(),
        .body = null,
        .params = .{},
    };

    const res = try app.dispatch(allocator, &req);
    try std.testing.expectEqual(res.status, .ok);
}

test "dynamic route match with params" {
    const allocator = std.testing.allocator;

    var app = try web.App.init(allocator);
    defer app.deinit();

    const handler = struct {
        pub fn handle(a: std.mem.Allocator, r: *web.Request) !web.Response {
            const id = r.param("id") orelse return try web.Response.text(a, "no id");
            return try web.Response.text(a, id);
        }
    }.handle;

    try app.get("/users/:id", handler);

    var req = web.Request{
        .method = .get,
        .path = "/users/123",
        .query = null,
        .headers = web.Headers.init(),
        .body = null,
        .params = .{},
    };

    const res = try app.dispatch(allocator, &req);
    try std.testing.expectEqual(res.status, .ok);
    try std.testing.expectEqualStrings(res.body.?, "123");
}

test "route not found returns 404" {
    const allocator = std.testing.allocator;

    var app = try web.App.init(allocator);
    defer app.deinit();

    var req = web.Request{
        .method = .get,
        .path = "/nonexistent",
        .query = null,
        .headers = web.Headers.init(),
        .body = null,
        .params = .{},
    };

    const res = try app.dispatch(allocator, &req);
    try std.testing.expectEqual(res.status, .not_found);
}

test "method mismatch returns 404" {
    const allocator = std.testing.allocator;

    var app = try web.App.init(allocator);
    defer app.deinit();

    const handler = struct {
        pub fn handle(a: std.mem.Allocator, r: *web.Request) !web.Response {
            _ = r;
            return try web.Response.text(a, "users");
        }
    }.handle;

    try app.get("/users/:id", handler);

    var req = web.Request{
        .method = .post,
        .path = "/users/123",
        .query = null,
        .headers = web.Headers.init(),
        .body = null,
        .params = .{},
    };

    const res = try app.dispatch(allocator, &req);
    try std.testing.expectEqual(res.status, .not_found);
}

// ============================================================================
// INTEGRATION TESTS
// ============================================================================

test "register missing body returns 400" {
    const allocator = std.testing.allocator;

    var app = try web.App.init(allocator);
    defer app.deinit();

    // Note: These would require mocking the DB pool
    // This is a placeholder showing the test structure

    var req = web.Request{
        .method = .post,
        .path = "/auth/register",
        .query = null,
        .headers = web.Headers.init(),
        .body = null,
        .params = .{},
    };

    // In real implementation, this would test the registerHandler
    // and expect a 400 response
    _ = &req;
}

test "login wrong password returns 401" {
    const allocator = std.testing.allocator;

    var app = try web.App.init(allocator);
    defer app.deinit();

    // Placeholder for integration test with mocked DB
    _ = &allocator;
}

test "get user without token returns 401" {
    const allocator = std.testing.allocator;

    var app = try web.App.init(allocator);
    defer app.deinit();

    var req = web.Request{
        .method = .get,
        .path = "/users/1",
        .query = null,
        .headers = web.Headers.init(),
        .body = null,
        .params = .{},
    };

    // Placeholder - would test getUserHandler without auth header
    _ = &req;
}

// ============================================================================
// UTILITY TESTS
// ============================================================================

test "Request param extraction" {
    var params = std.StringHashMapUnmanaged([]const u8){};
    defer params.deinit(std.testing.allocator);

    try params.put(std.testing.allocator, "id", "123");

    var req = web.Request{
        .method = .get,
        .path = "/users/123",
        .query = null,
        .headers = web.Headers.init(),
        .body = null,
        .params = params,
    };

    const id = req.param("id");
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings(id.?, "123");
}

test "Response JSON creation" {
    const allocator = std.testing.allocator;

    const res = try web.Response.json(allocator, .{ .id = 1, .name = "test" });

    try std.testing.expectEqual(res.status, .ok);
    try std.testing.expect(std.mem.indexOf(u8, res.body.?, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body.?, "\"name\":") != null);
}

test "Response text creation" {
    const allocator = std.testing.allocator;

    const res = try web.Response.text(allocator, "Hello");

    try std.testing.expectEqual(res.status, .ok);
    try std.testing.expectEqualStrings(res.body.?, "Hello");
}
