//! Google sign-in (`spider.google`): the OAuth authorization-code flow.
//! `login` sends the visitor to Google, `callback` receives them back,
//! checks that the login was started by this browser, and returns their
//! profile. No middleware and no session: the app decides what to do with
//! the profile (usually `spider.session.start`).
//!
//! ```zig
//! fn googleLogin(c: *spider.Ctx) !spider.Response {
//!     return spider.google.login(c, google_config);
//! }
//!
//! fn googleCallback(c: *spider.Ctx) !spider.Response {
//!     const profile = try spider.google.callback(c, google_config);
//!     return c.redirectWith("/", try spider.session.start(c, .{
//!         .id = profile.id, .email = profile.email, .name = profile.name,
//!     }));
//! }
//! ```

const std = @import("std");
const pacman = @import("pacman");
const url_util = @import("../internal/url.zig");
const Ctx = @import("../core/context.zig").Ctx;
const Response = @import("../core/context.zig").Response;

/// The OAuth client created in the Google Cloud console. Its id, secret and
/// redirect address have no default and nothing is read from the
/// environment: the app fills them. None of the strings is copied.
pub const GoogleConfig = struct {
    /// The OAuth client's id.
    client_id: []const u8,
    /// The OAuth client's secret, sent when the code is exchanged.
    client_secret: []const u8,
    /// The full URL of the app's callback route, as registered for the client.
    /// The login and the callback must be given the same value. When it
    /// starts with `http://`, `login` leaves `Secure` off its state cookie.
    redirect_uri: []const u8,
    /// Google's consent page. Like the two below, it is here so that a test
    /// can point the flow at a server of its own; an app leaves them alone.
    auth_endpoint: []const u8 = "https://accounts.google.com/o/oauth2/v2/auth",
    /// Where the code is exchanged for a token.
    token_endpoint: []const u8 = "https://oauth2.googleapis.com/token",
    /// Where the profile is read with the token.
    userinfo_endpoint: []const u8 = "https://www.googleapis.com/oauth2/v2/userinfo",
};

/// The cookie `login` sets and `callback` checks.
pub const state_cookie = "google_oauth_state";

/// What `callback` and `fetchProfile` fail with. When the handler returns
/// one, the server answers 400 for the first two, 401 for a refused code and
/// 502 when Google does not give the profile; an app's `onError` may show a
/// page instead.
pub const Error = error{
    /// The `state` of the callback is not the one this browser was given
    /// by `login` (or there is none): the login was not started here.
    OAuthStateMismatch,
    /// The callback came without a `code` (the visitor refused, usually).
    OAuthCodeMissing,
    /// Google did not accept the code: used before, expired, or made for
    /// another client or redirect address. In the code: the token endpoint
    /// did not answer 200 with a JSON body that has an `access_token`.
    OAuthCodeRejected,
    /// Google accepted the code and then did not return the profile: the
    /// userinfo endpoint did not answer 200 with a JSON body that has an
    /// `id`.
    OAuthProfileFailed,
};

/// For the route that starts the sign-in: redirects (302) the visitor to
/// Google's consent page with a random `state`, also kept in a cookie of this
/// browser (HttpOnly, SameSite=Lax, 10 minutes; Secure unless
/// `redirect_uri` is plain http, as on a developer's machine). `callback`
/// compares the two.
pub fn login(c: *Ctx, config: GoogleConfig) !Response {
    var random: [16]u8 = undefined;
    std.Io.random(c.io(), &random);
    const state = try c.arena.dupe(u8, &std.fmt.bytesToHex(random, .lower));

    var opts = try c.withCookie(state_cookie, state, .{
        .max_age = 600,
        .secure = !std.mem.startsWith(u8, config.redirect_uri, "http://"),
    });
    opts.status = .found;
    return c.redirectWith(try authUrlWith(c.arena, config, .{ .state = state }), opts);
}

/// For the callback route: checks the `state` against the cookie `login`
/// set, then exchanges the `code` and returns the profile (`fetchProfile`).
/// Nothing is asked of Google before the state matches. Fails with one of
/// `Error`, or with the HTTP client's error when Google cannot be reached.
/// The state is checked before the code, so a visitor who refused consent
/// gets error.OAuthCodeMissing. The cookie is not removed: it expires by
/// itself, 10 minutes after `login` set it.
pub fn callback(c: *Ctx, config: GoogleConfig) !GoogleProfile {
    const expected = c.cookie(state_cookie) orelse return error.OAuthStateMismatch;
    const given = c.queryDecoded("state") orelse return error.OAuthStateMismatch;
    if (expected.len == 0 or !std.mem.eql(u8, expected, given)) return error.OAuthStateMismatch;
    const code = c.queryDecoded("code") orelse return error.OAuthCodeMissing;
    if (code.len == 0) return error.OAuthCodeMissing;
    return fetchProfile(c, code, config);
}

/// The user as Google's userinfo endpoint describes them. The strings live in
/// the request arena. Only `id` is always there: the other three are empty
/// when Google's answer does not have them.
pub const GoogleProfile = struct {
    /// Google's stable id for the account.
    id: []const u8,
    email: []const u8,
    name: []const u8,
    /// URL of the account's picture.
    picture: []const u8,
};

/// The Google consent page to redirect the user to, asking for the `openid
/// email profile` scopes with `access_type=offline`. Allocated in `arena`;
/// the config values are URL-encoded. It adds no `state`: `login` does, and
/// is the one a login route should call (or `authUrlWith`, to send a state
/// of your own).
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

/// `authUrl` with a `state`, URL-encoded like the rest:
///
/// ```zig
/// const url = try spider.google.authUrlWith(c.arena, config, .{ .state = nonce });
/// ```
pub fn authUrlWith(arena: std.mem.Allocator, config: GoogleConfig, opts: AuthUrlOptions) ![]u8 {
    var url: std.ArrayList(u8) = .empty;
    try url.print(
        arena,
        "{s}?client_id={s}&redirect_uri={s}&response_type=code" ++
            "&scope=openid%20email%20profile&access_type=offline",
        .{
            config.auth_endpoint,
            try url_util.encodeQueryValue(arena, config.client_id),
            try url_util.encodeQueryValue(arena, config.redirect_uri),
        },
    );
    if (opts.state) |state| try url.print(arena, "&state={s}", .{try url_util.encodeQueryValue(arena, state)});
    return url.items;
}

// Profile is allocated in c.arena — freed automatically at end of request.
/// Exchanges `code` (the callback's `?code=`) for an access token and
/// fetches the user's profile with it: two HTTP requests to Google. The
/// profile is allocated in `c.arena`. It does not look at the `state`:
/// `callback` does, and is the one a callback route should call.
///
/// Fails with error.OAuthCodeRejected when Google does not accept the code,
/// error.OAuthProfileFailed when it then does not return the profile, or
/// the HTTP client's error when it cannot be reached.
pub fn fetchProfile(c: *Ctx, code: []const u8, config: GoogleConfig) !GoogleProfile {
    var token_res = try pacman.post(c.io(), c.arena, config.token_endpoint, .{
        .body = .{ .form = &.{
            .{ "code", code },
            .{ "client_id", config.client_id },
            .{ "client_secret", config.client_secret },
            .{ "redirect_uri", config.redirect_uri },
            .{ "grant_type", "authorization_code" },
        } },
    });
    defer token_res.deinit();
    if (token_res.status != .ok) {
        std.log.warn("[google] the code was refused: {d} {s}", .{ @backingInt(token_res.status), token_res.body_text });
        return error.OAuthCodeRejected;
    }

    const TokenResponse = struct { access_token: []const u8 = "" };
    const parsed_token = token_res.json(TokenResponse) catch return error.OAuthCodeRejected;
    defer parsed_token.deinit();
    if (parsed_token.value.access_token.len == 0) return error.OAuthCodeRejected;

    const auth_header = try std.fmt.allocPrint(
        c.arena,
        "Bearer {s}",
        .{parsed_token.value.access_token},
    );

    var profile_res = try pacman.get(c.io(), c.arena, config.userinfo_endpoint, .{
        .headers = &.{
            .{ .name = "Authorization", .value = auth_header },
        },
    });
    defer profile_res.deinit();
    if (profile_res.status != .ok) {
        std.log.warn("[google] no profile for the token: {d}", .{@backingInt(profile_res.status)});
        return error.OAuthProfileFailed;
    }

    const RawProfile = struct {
        id: []const u8,
        email: []const u8 = "",
        name: []const u8 = "",
        picture: []const u8 = "",
    };
    const parsed_profile = profile_res.json(RawProfile) catch return error.OAuthProfileFailed;
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
