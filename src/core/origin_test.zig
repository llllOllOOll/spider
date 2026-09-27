const std = @import("std");
const origin = @import("origin.zig");

const Req = struct {
    method: std.http.Method = .POST,
    path: []const u8 = "/items",
    host: ?[]const u8 = "app.example.com",
    origin: ?[]const u8 = null,
    sec_fetch_site: ?[]const u8 = null,
    upgrade: ?[]const u8 = null,
};

fn check(policy: origin.Policy, r: Req) bool {
    return origin.allowed(policy, .{
        .method = r.method,
        .path = r.path,
        .host = r.host,
        .origin = r.origin,
        .sec_fetch_site = r.sec_fetch_site,
        .upgrade = r.upgrade,
    });
}

const on: origin.Policy = .{};

test "origin: safe methods pass, whatever the site" {
    try std.testing.expect(check(on, .{ .method = .GET, .sec_fetch_site = "cross-site" }));
    try std.testing.expect(check(on, .{ .method = .HEAD, .sec_fetch_site = "cross-site" }));
    try std.testing.expect(check(on, .{ .method = .OPTIONS, .origin = "https://evil.example" }));
}

test "origin: Sec-Fetch-Site same-origin / none pass, same-site and cross-site don't" {
    try std.testing.expect(check(on, .{ .sec_fetch_site = "same-origin" }));
    try std.testing.expect(check(on, .{ .sec_fetch_site = "none" }));
    try std.testing.expect(!check(on, .{ .sec_fetch_site = "cross-site", .origin = "https://evil.example" }));
    // A sibling subdomain is "same-site": SameSite=Lax cookies go along, so it is refused too.
    try std.testing.expect(!check(on, .{ .sec_fetch_site = "same-site", .origin = "https://other.example.com" }));
}

test "origin: without Sec-Fetch-Site, Origin must match Host (older browsers)" {
    try std.testing.expect(check(on, .{ .origin = "https://app.example.com" }));
    try std.testing.expect(check(on, .{ .origin = "http://APP.example.com" }));
    try std.testing.expect(!check(on, .{ .origin = "https://evil.example" }));
    try std.testing.expect(!check(on, .{ .origin = "https://app.example.com.evil.example" }));
    try std.testing.expect(!check(on, .{ .origin = "null" }));
    // Ports are part of the origin.
    try std.testing.expect(check(on, .{ .host = "127.0.0.1:3000", .origin = "http://127.0.0.1:3000" }));
    try std.testing.expect(!check(on, .{ .host = "127.0.0.1:3000", .origin = "http://127.0.0.1:4000" }));
}

test "origin: no Origin and no Sec-Fetch-Site is a non-browser client and passes" {
    try std.testing.expect(check(on, .{}));
    try std.testing.expect(check(on, .{ .host = null }));
}

test "origin: a WebSocket upgrade is checked even though it is a GET" {
    try std.testing.expect(!check(on, .{ .method = .GET, .upgrade = "websocket", .sec_fetch_site = "cross-site", .origin = "https://evil.example" }));
    try std.testing.expect(!check(on, .{ .method = .GET, .upgrade = "WebSocket", .origin = "https://evil.example" }));
    try std.testing.expect(check(on, .{ .method = .GET, .upgrade = "websocket", .sec_fetch_site = "same-origin" }));
}

test "origin: trusted origins and exempt paths" {
    const p: origin.Policy = .{
        .trusted_origins = &.{"https://auth.example.com"},
        .exempt_paths = &.{ "/webhooks/", "/payments/callback" },
    };
    try std.testing.expect(check(p, .{ .sec_fetch_site = "same-site", .origin = "https://auth.example.com" }));
    try std.testing.expect(check(p, .{ .origin = "https://auth.example.com" }));
    try std.testing.expect(!check(p, .{ .sec_fetch_site = "cross-site", .origin = "https://evil.example" }));
    try std.testing.expect(check(p, .{ .path = "/webhooks/asaas", .sec_fetch_site = "cross-site", .origin = "https://evil.example" }));
    try std.testing.expect(check(p, .{ .path = "/payments/callback", .sec_fetch_site = "cross-site" }));
    try std.testing.expect(!check(p, .{ .path = "/payments/callbackX", .sec_fetch_site = "cross-site" }));
}

test "origin: disabled lets everything through" {
    try std.testing.expect(check(.{ .enabled = false }, .{ .sec_fetch_site = "cross-site", .origin = "https://evil.example" }));
}
