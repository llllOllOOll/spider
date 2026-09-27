const std = @import("std");
const context_mod = @import("context.zig");
const Ctx = context_mod.Ctx;
const RequestKind = Ctx.RequestKind;

fn makeCtx(alc: std.mem.Allocator, headers: []const [2][]const u8) !Ctx {
    var ctx = Ctx{
        .request = undefined,
        .arena = alc,
        .params = .{},
    };
    for (headers) |h| {
        try ctx._headers.put(alc, h[0], h[1]);
    }
    return ctx;
}

test "requestKind: HX-Request-Type=partial -> .fragment (htmx 4.0)" {
    const alc = std.testing.allocator;
    var ctx = try makeCtx(alc, &.{.{ "HX-Request-Type", "partial" }});
    defer ctx._headers.deinit(alc);

    try std.testing.expectEqual(RequestKind.fragment, ctx.requestKind());
}

test "requestKind: HX-Request-Type=full -> .full (htmx 4.0)" {
    const alc = std.testing.allocator;
    var ctx = try makeCtx(alc, &.{.{ "HX-Request-Type", "full" }});
    defer ctx._headers.deinit(alc);

    try std.testing.expectEqual(RequestKind.full, ctx.requestKind());
}

test "requestKind: no HX-Request-Type, HX-Boosted present -> .boosted (htmx 2.x)" {
    const alc = std.testing.allocator;
    var ctx = try makeCtx(alc, &.{.{ "HX-Boosted", "true" }});
    defer ctx._headers.deinit(alc);

    try std.testing.expectEqual(RequestKind.boosted, ctx.requestKind());
}

test "requestKind: no HX-Request-Type, HX-Request present -> .fragment (htmx 2.x)" {
    const alc = std.testing.allocator;
    var ctx = try makeCtx(alc, &.{.{ "HX-Request", "true" }});
    defer ctx._headers.deinit(alc);

    try std.testing.expectEqual(RequestKind.fragment, ctx.requestKind());
}

test "requestKind: no htmx headers at all -> .full (plain navigation)" {
    const alc = std.testing.allocator;
    var ctx = try makeCtx(alc, &.{});
    defer ctx._headers.deinit(alc);

    try std.testing.expectEqual(RequestKind.full, ctx.requestKind());
}

test "requestKind: HX-Request-Type wins over HX-Boosted/HX-Request when present" {
    const alc = std.testing.allocator;
    var ctx = try makeCtx(alc, &.{
        .{ "HX-Request-Type", "partial" },
        .{ "HX-Boosted", "true" },
        .{ "HX-Request", "true" },
    });
    defer ctx._headers.deinit(alc);

    try std.testing.expectEqual(RequestKind.fragment, ctx.requestKind());
}

test "isHtmx()/isBoosted() unaffected by the requestKind() addition (no regression)" {
    const alc = std.testing.allocator;
    var ctx = try makeCtx(alc, &.{ .{ "HX-Request", "true" }, .{ "HX-Boosted", "true" } });
    defer ctx._headers.deinit(alc);

    try std.testing.expect(ctx.isHtmx());
    try std.testing.expect(ctx.isBoosted());
}

test "isHtmx()/isBoosted() false when headers absent (no regression)" {
    const alc = std.testing.allocator;
    var ctx = try makeCtx(alc, &.{});
    defer ctx._headers.deinit(alc);

    try std.testing.expect(!ctx.isHtmx());
    try std.testing.expect(!ctx.isBoosted());
}

fn cookieCtx(a: std.mem.Allocator) Ctx {
    return Ctx{ .request = undefined, .arena = a, .params = .{}, .body = null };
}

test "setCookie: attributes, domain, and names/values that would inject are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = cookieCtx(arena.allocator());
    try std.testing.expectEqualStrings(
        "sid=abc; Path=/; Domain=example.com; Max-Age=60; SameSite=Lax; HttpOnly; Secure",
        try c.setCookie("sid", "abc", .{ .domain = "example.com", .max_age = 60 }),
    );
    // Spaces and UTF-8 in a value are fine (browsers accept them; apps store names).
    _ = try c.setCookie("operator_name", "João Silva", .{});
    try std.testing.expectError(error.InvalidCookie, c.setCookie("sid", "a; Domain=evil.example", .{}));
    try std.testing.expectError(error.InvalidCookie, c.setCookie("sid", "a\r\nSet-Cookie: x=1", .{}));
    try std.testing.expectError(error.InvalidCookie, c.setCookie("s id", "a", .{}));
    try std.testing.expectError(error.InvalidCookie, c.setCookie("sid=", "a", .{}));
    try std.testing.expectError(error.InvalidCookie, c.setCookie("", "a", .{}));
    try std.testing.expectError(error.InvalidCookie, c.setCookie("sid", "a", .{ .path = "/; HttpOnly" }));
    try std.testing.expectError(error.InvalidCookie, c.setCookie("sid", "a", .{ .same_site = "Lax\r\nX: 1" }));
}

test "deleteCookie: empty value, Max-Age=0, same path and domain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = cookieCtx(arena.allocator());
    try std.testing.expectEqualStrings(
        "sid=; Path=/app; Domain=example.com; Max-Age=0; SameSite=Lax; HttpOnly; Secure",
        try c.deleteCookie("sid", .{ .path = "/app", .domain = "example.com" }),
    );
}

test "htmx: response headers from typed options, in a stable order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = cookieCtx(arena.allocator());
    const hdrs = try c.htmx(.{
        .trigger = try c.hxEvent("spider:toast", .{ .message = "Salvo ✓", .type = "success" }),
        .retarget = "#form",
        .reswap = .outerHTML,
        .push_url = "/posts/1",
        .refresh = true,
    });
    try std.testing.expectEqual(@as(usize, 5), hdrs.len);
    try std.testing.expectEqualStrings("HX-Trigger", hdrs[0][0]);
    try std.testing.expectEqualStrings("{\"spider:toast\":{\"message\":\"Salvo \\u2713\",\"type\":\"success\"}}", hdrs[0][1]);
    try std.testing.expectEqualStrings("HX-Retarget", hdrs[1][0]);
    try std.testing.expectEqualStrings("#form", hdrs[1][1]);
    try std.testing.expectEqualStrings("HX-Reswap", hdrs[2][0]);
    try std.testing.expectEqualStrings("outerHTML", hdrs[2][1]);
    try std.testing.expectEqualStrings("HX-Push-Url", hdrs[3][0]);
    try std.testing.expectEqualStrings("HX-Refresh", hdrs[4][0]);
    try std.testing.expectEqualStrings("true", hdrs[4][1]);
    try std.testing.expectEqual(@as(usize, 0), (try c.htmx(.{})).len);
}

test "htmx: header values with CR/LF are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = cookieCtx(arena.allocator());
    try std.testing.expectError(error.InvalidHeaderValue, c.htmx(.{ .redirect = "/x\r\nSet-Cookie: a=b" }));
}
