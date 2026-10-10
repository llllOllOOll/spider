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

test "statusForError: invalid or expired tokens are 401, not 500" {
    try std.testing.expectEqual(std.http.Status.unauthorized, context_mod.statusForError(error.Expired));
    try std.testing.expectEqual(std.http.Status.unauthorized, context_mod.statusForError(error.InvalidSignature));
    try std.testing.expectEqual(std.http.Status.unauthorized, context_mod.statusForError(error.InvalidFormat));
}

test "download: the whole response, headers exactly once" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var ctx = try makeCtx(arena_state.allocator(), &.{});
    const bytes = "PK\x03\x04 not really a workbook";

    const res = try ctx.download(bytes, .{ .filename = "Relatório.xlsx", .content_type = context_mod.content_types.xlsx });
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    // The body is the caller's bytes, not a copy.
    try std.testing.expect(res.body.?.ptr == bytes.ptr and res.body.?.len == bytes.len);
    try std.testing.expectEqualStrings("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", res.content_type);
    try std.testing.expectEqual(@as(usize, 2), res.headers.len);
    try std.testing.expectEqualStrings("Content-Disposition", res.headers[0][0]);
    try std.testing.expectEqualStrings("attachment; filename=\"Relatorio.xlsx\"; filename*=UTF-8''Relat%C3%B3rio.xlsx", res.headers[0][1]);
    try std.testing.expectEqualStrings("X-Content-Type-Options", res.headers[1][0]);
    try std.testing.expectEqualStrings("nosniff", res.headers[1][1]);
    // Content-Type and Content-Length are written by the server, once:
    // the helper must not add them as extra headers.
    for (res.headers) |h| {
        try std.testing.expect(!std.ascii.eqlIgnoreCase(h[0], "Content-Type"));
        try std.testing.expect(!std.ascii.eqlIgnoreCase(h[0], "Content-Length"));
    }

    // Defaults, extra headers, inline, cookies and status are passed on.
    const plain = try ctx.download("x", .{ .filename = "dados.bin" });
    try std.testing.expectEqualStrings("application/octet-stream", plain.content_type);
    const shown = try ctx.download("%PDF", .{
        .filename = "ata.pdf",
        .content_type = context_mod.content_types.pdf,
        .disposition = .@"inline",
        .headers = &.{.{ "Cache-Control", "no-store" }},
        .cookies = &.{.{ "seen", "seen=1; Path=/" }},
    });
    try std.testing.expectEqualStrings("inline; filename=\"ata.pdf\"", shown.headers[0][1]);
    try std.testing.expectEqualStrings("Cache-Control", shown.headers[2][0]);
    try std.testing.expectEqual(@as(usize, 1), shown.cookies.len);

    // A content type that could split the header is refused.
    try std.testing.expectError(error.InvalidContentType, ctx.download("x", .{ .filename = "a.txt", .content_type = "text/plain\r\nX-Injected: 1" }));
    try std.testing.expectError(error.InvalidContentType, ctx.download("x", .{ .filename = "a.txt", .content_type = "" }));
}

test "download: running out of memory leaks nothing" {
    const Run = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            var ctx = try makeCtx(arena_state.allocator(), &.{});
            _ = try ctx.download("bytes", .{ .filename = "Relatório \"x\".csv", .content_type = context_mod.content_types.csv, .headers = &.{.{ "Cache-Control", "no-store" }} });
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Run.run, .{});
}

test "setCookie with .encode: any text is a valid value, cookieDecoded reads it back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = cookieCtx(a);
    try std.testing.expectError(error.InvalidCookie, c.setCookie("author", "Zé; da \"Silva\"", .{}));
    try std.testing.expectEqualStrings(
        "author=Z%C3%A9%3B%20da%20%22Silva%22; Path=/; SameSite=Lax; HttpOnly; Secure",
        try c.setCookie("author", "Zé; da \"Silva\"", .{ .encode = true }),
    );
    const opts = try c.withCookie("author", "a b", .{ .encode = true });
    try std.testing.expectEqualStrings("author=a%20b; Path=/; SameSite=Lax; HttpOnly; Secure", opts.headers[0][1]);

    var reader = try makeCtx(a, &.{.{ "Cookie", "sid=abc; author=Z%C3%A9%3B%20da%20%22Silva%22; plain=a+b" }});
    try std.testing.expectEqualStrings("Zé; da \"Silva\"", reader.cookieDecoded("author").?);
    try std.testing.expectEqualStrings("Z%C3%A9%3B%20da%20%22Silva%22", reader.cookie("author").?);
    try std.testing.expectEqualStrings("a+b", reader.cookieDecoded("plain").?);
    try std.testing.expect(reader.cookieDecoded("missing") == null);
}

test "redirectWith: 303 by default, keeps headers and cookies, another 3xx is kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = cookieCtx(arena.allocator());

    const res = try c.redirectWith("/posts/5", try c.withCookie("author", "Ana", .{}));
    try std.testing.expectEqual(std.http.Status.see_other, res.status);
    try std.testing.expectEqualStrings("Location", res.headers[0][0]);
    try std.testing.expectEqualStrings("/posts/5", res.headers[0][1]);
    try std.testing.expectEqualStrings("Set-Cookie", res.headers[1][0]);
    try std.testing.expect(std.mem.startsWith(u8, res.headers[1][1], "author=Ana;"));

    const moved = try c.redirectWith("/new", .{ .status = .moved_permanently });
    try std.testing.expectEqual(std.http.Status.moved_permanently, moved.status);
    const plain = try c.redirect("/x");
    try std.testing.expectEqual(std.http.Status.found, plain.status);
}

test "io() is the Io the server gave the request" {
    var c = Ctx{ .request = undefined, .arena = std.testing.allocator, .params = .{}, .body = null };
    c._io = std.testing.io;
    try std.testing.expectEqual(std.testing.io.vtable, c.io().vtable);
}

test "htmxRedirect: a header for a request htmx made, an ordinary redirect for any other" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    // A form htmx posted: the next address goes in HX-Redirect. A 3xx
    // would be followed by the browser, and htmx would be handed the next
    // page as the thing to swap in.
    var posted = try makeCtx(alc, &.{.{ "HX-Request", "true" }});
    const for_htmx = try posted.htmxRedirect("/bookings/7");
    try std.testing.expectEqual(std.http.Status.ok, for_htmx.status);
    try std.testing.expectEqual(@as(usize, 1), for_htmx.headers.len);
    try std.testing.expectEqualStrings("HX-Redirect", for_htmx.headers[0][0]);
    try std.testing.expectEqualStrings("/bookings/7", for_htmx.headers[0][1]);

    // The same form posted by the browser itself.
    var plain = try makeCtx(alc, &.{});
    const for_browser = try plain.htmxRedirect("/bookings/7");
    try std.testing.expectEqual(std.http.Status.see_other, for_browser.status);
    try std.testing.expectEqualStrings("Location", for_browser.headers[0][0]);
    try std.testing.expectEqualStrings("/bookings/7", for_browser.headers[0][1]);

    try std.testing.expectError(error.InvalidHeaderValue, posted.htmxRedirect("/x\r\nSet-Cookie: a=b"));
}
