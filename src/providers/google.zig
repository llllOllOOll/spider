//! Google sign-in (`spider.google`): the two calls of the OAuth
//! authorization-code flow. No middleware and no session: the app decides what
//! to do with the profile (usually `spider.session.start`).

const std = @import("std");
const pacman = @import("pacman");
const url_util = @import("../internal/url.zig");
const Ctx = @import("../core/context.zig").Ctx;

/// The OAuth client created in the Google Cloud console. No field has a
/// default and nothing is read from the environment: the app fills it.
pub const GoogleConfig = struct {
    /// The OAuth client's id.
    client_id: []const u8,
    /// The OAuth client's secret, sent when the code is exchanged.
    client_secret: []const u8,
    /// The full URL of the app's callback route, as registered for the client.
    /// The same value must be given to `authUrl` and `fetchProfile`.
    redirect_uri: []const u8,
};

/// The user as Google's userinfo endpoint describes them. The strings live in
/// the request arena.
pub const GoogleProfile = struct {
    /// Google's stable id for the account.
    id: []const u8,
    email: []const u8,
    name: []const u8,
    /// URL of the account's picture.
    picture: []const u8,
};

/// The Google consent page to redirect the user to, asking for the `openid
/// email profile` scopes. Allocated in `arena`; the config values are
/// URL-encoded. It adds no `state`: use `authUrlWith` to send one.
pub fn authUrl(arena: std.mem.Allocator, config: GoogleConfig) ![]u8 {
    return authUrlWith(arena, config, .{});
}

/// Options of `authUrlWith`.
pub const AuthUrlOptions = struct {
    /// Sent to Google and given back to the redirect address as `?state=`.
    /// Put something only this visitor's browser holds (a random value
    /// also kept in a cookie) and compare the two in the callback: without
    /// it, someone else can finish a login in the visitor's browser.
    state: ?[]const u8 = null,
};

/// `authUrl` with a `state`:
///
/// ```zig
/// const url = try spider.google.authUrlWith(c.arena, config, .{ .state = nonce });
/// ```
pub fn authUrlWith(arena: std.mem.Allocator, config: GoogleConfig, opts: AuthUrlOptions) ![]u8 {
    var url: std.ArrayList(u8) = .empty;
    try url.print(
        arena,
        "https://accounts.google.com/o/oauth2/v2/auth" ++
            "?client_id={s}&redirect_uri={s}&response_type=code" ++
            "&scope=openid%20email%20profile&access_type=offline",
        .{
            try url_util.encodeQueryValue(arena, config.client_id),
            try url_util.encodeQueryValue(arena, config.redirect_uri),
        },
    );
    if (opts.state) |state| try url.print(arena, "&state={s}", .{try url_util.encodeQueryValue(arena, state)});
    return url.items;
}

// Profile is allocated in c.arena — freed automatically at end of request.
/// For the callback route: exchanges `code` (the callback's `?code=`) for an
/// access token and fetches the user's profile with it. Two HTTP requests to
/// Google. The profile is allocated in `c.arena`. Fails with the HTTP
/// client's error, or with the JSON parser's error when Google answers with
/// something else than a token or a profile (a refused code, for one).
pub fn fetchProfile(c: *Ctx, code: []const u8, config: GoogleConfig) !GoogleProfile {
    var token_res = try pacman.post(c._io, c.arena, "https://oauth2.googleapis.com/token", .{
        .body = .{ .form = &.{
            .{ "code", code },
            .{ "client_id", config.client_id },
            .{ "client_secret", config.client_secret },
            .{ "redirect_uri", config.redirect_uri },
            .{ "grant_type", "authorization_code" },
        } },
    });
    defer token_res.deinit();

    const TokenResponse = struct { access_token: []const u8 };
    const parsed_token = try token_res.json(TokenResponse);
    defer parsed_token.deinit();

    const auth_header = try std.fmt.allocPrint(
        c.arena,
        "Bearer {s}",
        .{parsed_token.value.access_token},
    );

    var profile_res = try pacman.get(c._io, c.arena, "https://www.googleapis.com/oauth2/v2/userinfo", .{
        .headers = &.{
            .{ .name = "Authorization", .value = auth_header },
        },
    });
    defer profile_res.deinit();

    const RawProfile = struct {
        id: []const u8,
        email: []const u8,
        name: []const u8,
        picture: []const u8,
    };
    const parsed_profile = try profile_res.json(RawProfile);
    defer parsed_profile.deinit();

    return GoogleProfile{
        .id = try c.arena.dupe(u8, parsed_profile.value.id),
        .email = try c.arena.dupe(u8, parsed_profile.value.email),
        .name = try c.arena.dupe(u8, parsed_profile.value.name),
        .picture = try c.arena.dupe(u8, parsed_profile.value.picture),
    };
}

test "authUrl: the redirect address is one parameter, whatever it contains" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const url = try authUrl(arena.allocator(), .{
        .client_id = "id 1",
        .client_secret = "secret",
        .redirect_uri = "http://localhost:3000/auth/google?from=a&to=b",
    });
    // The redirect's own "&to=b" must not become a parameter of Google's URL.
    try std.testing.expect(std.mem.indexOf(u8, url, "&to=b") == null);
    try std.testing.expect(std.mem.indexOf(u8, url, "redirect_uri=http%3A//localhost%3A3000/auth/google%3Ffrom%3Da%26to%3Db&") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "client_id=id%201&") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "&response_type=code&scope=openid%20email%20profile&access_type=offline") != null);
}

test "authUrlWith: the state goes along, encoded" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const config: GoogleConfig = .{ .client_id = "id", .client_secret = "secret", .redirect_uri = "https://app.example.com/cb" };
    const url = try authUrlWith(arena.allocator(), config, .{ .state = "a b&c" });
    try std.testing.expect(std.mem.endsWith(u8, url, "&access_type=offline&state=a%20b%26c"));
    try std.testing.expectEqualStrings(try authUrl(arena.allocator(), config), try authUrlWith(arena.allocator(), config, .{}));
}
