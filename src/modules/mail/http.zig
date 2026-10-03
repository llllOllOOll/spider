//! What the HTTP transports share: posting a JSON payload to a provider and
//! turning its answer into a mail error.

const std = @import("std");
const builtin = @import("builtin");
const pacman = @import("pacman");

// warn under `zig test` only: the test runner fails any test that logs at
// err level, and the tests trigger these on purpose.
const log = if (builtin.is_test) std.log.warn else std.log.err;

pub const Reply = struct {
    status: std.http.Status,
    body: []const u8,
};

/// POSTs `body` as JSON. A request that gets no answer at all is
/// `error.MailDeliveryFailed`; any HTTP answer comes back as a Reply.
pub fn postJson(
    arena: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    headers: []const std.http.Header,
    body: []const u8,
) !Reply {
    var res = pacman.post(io, arena, url, .{
        .body = .{ .json = body },
        .headers = headers,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        log("mail: request to {s} failed: {s}", .{ url, @errorName(err) });
        return error.MailDeliveryFailed;
    };
    defer res.deinit();
    return .{ .status = res.status, .body = try arena.dupe(u8, res.body_text) };
}

pub const StatusError = error{ MailUnauthorized, MailRejected, MailDeliveryFailed };

/// 2xx is success. 401/403: the credentials were refused. 408/429, 3xx and
/// 5xx: worth retrying later (MailDeliveryFailed). Any other 4xx: the
/// provider refused this message, retrying it unchanged won't help.
pub fn classify(status: std.http.Status) ?StatusError {
    const code = @intFromEnum(status);
    if (code >= 200 and code < 300) return null;
    if (code == 401 or code == 403) return error.MailUnauthorized;
    if (code == 408 or code == 429) return error.MailDeliveryFailed;
    if (code >= 400 and code < 500) return error.MailRejected;
    return error.MailDeliveryFailed;
}

/// Fails with the error for the reply's status, logging what the provider
/// said (its body explains a rejection).
pub fn check(provider: []const u8, reply: Reply) StatusError!void {
    const err = classify(reply.status) orelse return;
    log("mail: {s} answered {d}: {s}", .{
        provider,
        @intFromEnum(reply.status),
        reply.body[0..@min(reply.body.len, 500)],
    });
    return err;
}

/// The string at `key` of a JSON object, or null when the body is not an
/// object or has no such string.
pub fn jsonString(arena: std.mem.Allocator, body: []const u8, key: []const u8) ?[]const u8 {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    if (field != .string) return null;
    return field.string;
}

/// Serializes a provider payload, leaving out the optional fields that are null.
pub fn stringify(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{ .emit_null_optional_fields = false });
}

// ── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "classify: 2xx is success" {
    try testing.expect(classify(.ok) == null);
    try testing.expect(classify(.created) == null);
    try testing.expect(classify(.accepted) == null);
    try testing.expect(classify(.no_content) == null);
}

test "classify: refused credentials" {
    try testing.expectEqual(@as(?StatusError, error.MailUnauthorized), classify(.unauthorized));
    try testing.expectEqual(@as(?StatusError, error.MailUnauthorized), classify(.forbidden));
}

test "classify: a message the provider refuses" {
    try testing.expectEqual(@as(?StatusError, error.MailRejected), classify(.bad_request));
    try testing.expectEqual(@as(?StatusError, error.MailRejected), classify(.not_found));
    try testing.expectEqual(@as(?StatusError, error.MailRejected), classify(.unprocessable_entity));
}

test "classify: failures worth retrying" {
    try testing.expectEqual(@as(?StatusError, error.MailDeliveryFailed), classify(.request_timeout));
    try testing.expectEqual(@as(?StatusError, error.MailDeliveryFailed), classify(.too_many_requests));
    try testing.expectEqual(@as(?StatusError, error.MailDeliveryFailed), classify(.internal_server_error));
    try testing.expectEqual(@as(?StatusError, error.MailDeliveryFailed), classify(.service_unavailable));
    try testing.expectEqual(@as(?StatusError, error.MailDeliveryFailed), classify(.found));
}

test "check: passes a success through and fails with the classified error" {
    try check("test", .{ .status = .created, .body = "{}" });
    try testing.expectError(error.MailUnauthorized, check("test", .{ .status = .unauthorized, .body = "{\"message\":\"Key not found\"}" }));
    try testing.expectError(error.MailRejected, check("test", .{ .status = .bad_request, .body = "" }));
    const long_body: [2000]u8 = @splat('x');
    try testing.expectError(error.MailDeliveryFailed, check("test", .{ .status = .bad_gateway, .body = &long_body }));
}

test "jsonString: reads a string field" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("abc", jsonString(arena, "{\"id\":\"abc\",\"n\":1}", "id").?);
    try testing.expect(jsonString(arena, "{\"id\":\"abc\"}", "other") == null);
    try testing.expect(jsonString(arena, "{\"id\":42}", "id") == null);
    try testing.expect(jsonString(arena, "[\"id\"]", "id") == null);
    try testing.expect(jsonString(arena, "not json", "id") == null);
    try testing.expect(jsonString(arena, "", "id") == null);
}

test "stringify: null optional fields are left out and strings are escaped" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const P = struct { a: []const u8, b: ?[]const u8 = null, c: ?[]const u8 = null };
    try testing.expectEqualStrings(
        "{\"a\":\"say \\\"hi\\\"\\n\",\"c\":\"x\"}",
        try stringify(arena_state.allocator(), P{ .a = "say \"hi\"\n", .c = "x" }),
    );
}
