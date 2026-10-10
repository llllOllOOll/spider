//! Internal: small URL helpers shared by the auth providers.

const std = @import("std");

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

/// Percent-encodes `s` for use as a single query-string value. Everything
/// except RFC 3986 unreserved characters and '/' is encoded, so a full
/// "/path?a=1&b=2" survives as ONE parameter value.
pub fn encodeQueryValue(alc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alc);
    for (s) |c| {
        if (isUnreserved(c) or c == '/') {
            try out.append(alc, c);
        } else {
            try out.print(alc, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(alc);
}

/// Decodes %XX sequences and '+' (as space). Malformed escapes are an error
/// rather than being passed through, so a caller validating the decoded
/// value never sees a half-decoded string.
pub fn decodeQueryValue(alc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try alc.alloc(u8, s.len);
    errdefer alc.free(out);
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) : (n += 1) {
        switch (s[i]) {
            '%' => {
                if (i + 2 >= s.len) return error.InvalidPercentEncoding;
                out[n] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return error.InvalidPercentEncoding;
                i += 3;
            },
            '+' => {
                out[n] = ' ';
                i += 1;
            },
            else => |c| {
                out[n] = c;
                i += 1;
            },
        }
    }
    return alc.realloc(out, n);
}

/// True when `target` is safe to put in a Location header as an
/// after-login/after-refresh destination: a path on THIS origin.
///
/// Rejects anything a browser could resolve to another origin:
/// absolute URLs ("https://x"), scheme-relative ("//x"), backslash tricks
/// ("/\x", which browsers normalize to "//x"), and any ASCII control char
/// (browsers strip tab/CR/LF inside URLs, so "/\t/x" becomes "//x"; CR/LF
/// would also allow header injection).
pub fn isSafeLocalRedirect(target: []const u8) bool {
    if (target.len == 0 or target[0] != '/') return false;
    if (target.len > 1 and (target[1] == '/' or target[1] == '\\')) return false;
    for (target) |c| {
        if (c < 0x20 or c == 0x7f or c == '\\') return false;
    }
    return true;
}

// ── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "isSafeLocalRedirect: accepts local paths" {
    try t.expect(isSafeLocalRedirect("/"));
    try t.expect(isSafeLocalRedirect("/dashboard"));
    try t.expect(isSafeLocalRedirect("/tickets/42?tab=history&x=1"));
    try t.expect(isSafeLocalRedirect("/a/b#frag"));
    try t.expect(isSafeLocalRedirect("/path%2F%2Fencoded"));
}

test "isSafeLocalRedirect: rejects other origins and tricks" {
    const bad = [_][]const u8{
        "",
        "https://evil.com",
        "http:/evil.com",
        "javascript:alert(1)",
        "//evil.com",
        "//evil.com/path",
        "/\\evil.com",
        "\\\\evil.com",
        "/ok\\..\\x",
        "/\t/evil.com",
        "/\r\nSet-Cookie: x=1",
        "/\n/evil.com",
        "evil.com",
        "dashboard",
        "/x\x7f",
    };
    for (bad) |b| {
        if (isSafeLocalRedirect(b)) {
            std.debug.print("accepted unsafe target: {s}\n", .{b});
            return error.TestUnexpectedResult;
        }
    }
}

test "encodeQueryValue: keeps path, encodes query separators" {
    const out = try encodeQueryValue(t.allocator, "/tickets/42?tab=a b&x=1");
    defer t.allocator.free(out);
    try t.expectEqualStrings("/tickets/42%3Ftab%3Da%20b%26x%3D1", out);
}

test "decodeQueryValue: round-trips encodeQueryValue" {
    const inputs = [_][]const u8{ "/", "/a?b=c&d=e", "/ç/ã?q=1+2", "/x#y", "" };
    for (inputs) |in| {
        const enc = try encodeQueryValue(t.allocator, in);
        defer t.allocator.free(enc);
        const dec = try decodeQueryValue(t.allocator, enc);
        defer t.allocator.free(dec);
        try t.expectEqualStrings(in, dec);
    }
}

test "decodeQueryValue: decodes plus and mixed case hex" {
    const out = try decodeQueryValue(t.allocator, "a+b%2fc%2F");
    defer t.allocator.free(out);
    try t.expectEqualStrings("a b/c/", out);
}

test "decodeQueryValue: malformed escapes are errors" {
    try t.expectError(error.InvalidPercentEncoding, decodeQueryValue(t.allocator, "%"));
    try t.expectError(error.InvalidPercentEncoding, decodeQueryValue(t.allocator, "%2"));
    try t.expectError(error.InvalidPercentEncoding, decodeQueryValue(t.allocator, "abc%zz"));
}

test "decoded encoded-attack payloads are rejected" {
    // What a crafted ?next= would decode to.
    const attacks = [_][]const u8{ "%2F%2Fevil.com", "%2F%5Cevil.com", "https%3A%2F%2Fevil.com", "%2F%0D%0ASet-Cookie:x" };
    for (attacks) |a| {
        const dec = try decodeQueryValue(t.allocator, a);
        defer t.allocator.free(dec);
        try t.expect(!isSafeLocalRedirect(dec));
    }
}

// internal: the rule the auth providers share for their cookies.
/// Whether a cookie set by an app reached at `app_url` (its OAuth redirect
/// address) carries `Secure`: yes, unless that address is plain http. A
/// browser does not keep a Secure cookie that arrives over http, so a
/// login on a developer's machine would never complete.
pub fn cookiesSecureFor(app_url: []const u8) bool {
    return !std.ascii.startsWithIgnoreCase(app_url, "http://");
}

test "cookiesSecureFor: Secure unless the app is reached over plain http" {
    try std.testing.expect(cookiesSecureFor("https://app.example.com/auth/callback"));
    try std.testing.expect(!cookiesSecureFor("http://localhost:3000/auth/callback"));
    try std.testing.expect(!cookiesSecureFor("HTTP://192.168.0.10/auth/callback"));
    // Anything that is not clearly http stays on the safe side.
    try std.testing.expect(cookiesSecureFor("/auth/callback"));
}
