//! Clerk login (`spider.clerk`): the token check of `spider.jwks` configured
//! from a Clerk publishable key, plus the OAuth callback that sets the session
//! cookie.

const std = @import("std");
const pacman = @import("pacman");
const Ctx = @import("../core/context.zig").Ctx;
const Response = @import("../core/context.zig").Response;
const MiddlewareFn = @import("../core/context.zig").MiddlewareFn;
const Handler = @import("../routing/router.zig").Handler;
const jwks = @import("jwks.zig");
const JwksAuth = jwks.JwksAuth;

/// What `Clerk.init` takes. Nothing is read from the environment: the app
/// fills it.
pub const ClerkConfig = struct {
    /// The instance's publishable key (`pk_test_...` or `pk_live_...`). The
    /// issuer and the JWKS URL are derived from it (see `Clerk.init`); it is
    /// also sent as the OAuth `client_id`. No default.
    publishable_key: []const u8,
    /// Sent as the OAuth `client_secret` when the callback exchanges the code.
    /// No default.
    secret_key: []const u8,
    /// The full URL of the app's callback route (`callbackHandler()`).
    redirect_uri: []const u8 = "http://localhost:3000/auth/callback",
    /// Where a request without a token is redirected.
    login_path: []const u8 = "/login",
    /// Where the callback redirects once the session cookie is set.
    after_callback_path: []const u8 = "/",
    /// Where the session token carries roles (what `.roles` checks); Clerk
    /// has none by default — add one with a custom session claim, e.g.
    /// {"roles": "{{user.public_metadata.roles}}"} and roles_claim = "roles".
    /// The active organization's role (what `.org_roles` checks) is read
    /// without configuration. See JwksConfig.roles_claim.
    roles_claim: ?[]const u8 = null,
    /// See JwksConfig.map_claims.
    map_claims: ?*const fn (c: *Ctx, claims: std.json.ObjectMap) anyerror!void = null,
};

/// One Clerk instance for the app. The middleware and the callback handler
/// keep a pointer to this value: it must not move or be freed while the
/// server runs, and a process can use one.
///
/// ```zig
/// var clerk = try spider.clerk.Clerk.init(allocator, io, .{
///     .publishable_key = publishable_key,
///     .secret_key = secret_key,
/// });
/// defer clerk.deinit();
/// server
///     .use(clerk.middleware())
///     .get("/auth/callback", clerk.callbackHandler(), .{ .public = true });
/// ```
pub const Clerk = struct {
    /// The token verifier (`spider.jwks.JwksAuth`), with `.org_claims = .clerk`.
    jwks: JwksAuth,
    /// The config given to `init`. Its strings are not copied.
    config: ClerkConfig,
    /// The issuer decoded from the publishable key: the base of the JWKS and
    /// OAuth URLs.
    domain: []const u8,

    /// Decodes the issuer from the publishable key and downloads the signing
    /// keys from `{issuer}/.well-known/jwks.json`. What follows the key's
    /// `pk_live_` / `pk_test_` prefix is base64 of the host of the
    /// instance's Frontend API followed by a `$`
    /// (`example.accounts.dev$`): the issuer is that host over https. (A
    /// key that decodes to JSON with an `issuer` field is used as that
    /// issuer, scheme included: for tests against a server of your own.)
    ///
    /// Errors: error.InvalidClerkKey (no such prefix, not base64, or it
    /// decodes to nothing), error.JwksFetchFailed when the address does not
    /// answer with a key set, or the HTTP client's error when it cannot be
    /// reached.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: ClerkConfig) !Clerk {
        const domain = try parseIssuerUrl(allocator, config.publishable_key);
        errdefer allocator.free(domain);
        // Kept for as long as the Clerk lives: the verifier downloads the
        // keys again from it when a token names a key it does not know.
        const jwks_url = try std.fmt.allocPrint(allocator, "{s}/.well-known/jwks.json", .{domain});
        errdefer allocator.free(jwks_url);
        const jwks_auth = try JwksAuth.init(allocator, io, .{
            .jwks_url = jwks_url,
            .issuer = domain,
            .cookie_name = "__session",
            .login_path = config.login_path,
            .after_callback_path = config.after_callback_path,
            .roles_claim = config.roles_claim,
            .org_claims = .clerk,
            .map_claims = config.map_claims,
        });
        return Clerk{
            .jwks = jwks_auth,
            .config = config,
            .domain = domain,
        };
    }

    /// Frees the cached keys and the two addresses `init` built.
    pub fn deinit(self: *Clerk) void {
        const allocator = self.jwks.allocator;
        allocator.free(self.jwks.config.jwks_url);
        allocator.free(self.domain);
        self.jwks.deinit();
    }

    /// The URL that starts the OAuth flow (`{issuer}/oauth/authorize`), to
    /// redirect the user to. Allocated in `arena`. The values are not
    /// URL-encoded and no `state` parameter is added.
    pub fn authUrl(self: *const Clerk, arena: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            arena,
            "{s}/oauth/authorize?response_type=code&client_id={s}&redirect_uri={s}",
            .{ self.domain, self.config.publishable_key, self.config.redirect_uri },
        );
    }

    /// The middleware that checks the `__session` token of every request (see
    /// `JwksAuth.middleware`): `server.use(clerk.middleware())`. Only routes
    /// marked `.public` pass without a token (there is no list of skipped
    /// paths), an expired token is a 401 (there is no refresh route), and the
    /// token's audience is not checked.
    pub fn middleware(self: *Clerk) MiddlewareFn {
        return self.jwks.middleware();
    }

    /// The handler for the route named by `redirect_uri`: exchanges `code`
    /// for tokens, sets the `__session` cookie (the ID token, or the access
    /// token when there is none; 7 days) and redirects to
    /// `after_callback_path`. 400 without `code`; 502 when Clerk returns no
    /// token. The OAuth `state` is not checked. Mark the route `.public`, or
    /// the middleware stops the callback before it gets here.
    pub fn callbackHandler(self: *Clerk) Handler {
        const S = struct {
            var instance: ?*Clerk = null;
            fn h(c: *Ctx) anyerror!Response {
                return instance.?.callbackFn(c);
            }
        };
        S.instance = self;
        return S.h;
    }

    fn callbackFn(self: *Clerk, c: *Ctx) !Response {
        const code = c.query("code") orelse
            return c.text("Missing authorization code", .{ .status = .bad_request });

        const token_url = try std.fmt.allocPrint(c.arena, "{s}/oauth/token", .{self.domain});

        var res = try pacman.post(c._io, c.arena, token_url, .{
            .body = .{ .form = &.{
                .{ "grant_type", "authorization_code" },
                .{ "code", code },
                .{ "client_id", self.config.publishable_key },
                .{ "client_secret", self.config.secret_key },
                .{ "redirect_uri", self.config.redirect_uri },
            } },
        });
        defer res.deinit();

        const parsed = try res.json(struct {
            id_token: []const u8 = "",
            access_token: []const u8 = "",
        });
        defer parsed.deinit();

        const jwt = if (parsed.value.id_token.len > 0) parsed.value.id_token else parsed.value.access_token;
        if (jwt.len == 0)
            return c.text("No token received from Clerk", .{ .status = .bad_gateway });

        const cookie_str = try c.setCookie("__session", jwt, .{
            .http_only = true,
            .secure = true,
            .same_site = "Lax",
            .path = "/",
            .max_age = 86400 * 7,
        });

        // In the request's arena: the response is sent after this returns.
        const headers = try c.arena.alloc([2][]const u8, 2);
        headers[0] = .{ "Location", self.config.after_callback_path };
        headers[1] = .{ "Set-Cookie", cookie_str };
        return Response{ .status = .found, .headers = headers };
    }
};

fn parseIssuerUrl(allocator: std.mem.Allocator, publishable_key: []const u8) ![]const u8 {
    const prefix = if (std.mem.startsWith(u8, publishable_key, "pk_live_"))
        "pk_live_"
    else if (std.mem.startsWith(u8, publishable_key, "pk_test_"))
        "pk_test_"
    else
        return error.InvalidClerkKey;

    // What follows the prefix is base64 of the instance's address. Clerk
    // writes it with the standard alphabet and its `=` padding; the other
    // alphabet, and no padding, are read too.
    const b64_data = std.mem.trimEnd(u8, publishable_key[prefix.len..], "=");
    if (b64_data.len == 0) return error.InvalidClerkKey;
    const decoded = blk: {
        inline for (.{ std.base64.standard_no_pad, std.base64.url_safe_no_pad }) |codec| {
            if (codec.Decoder.calcSizeForSlice(b64_data)) |size| {
                const buf = try allocator.alloc(u8, size);
                if (codec.Decoder.decode(buf, b64_data)) |_| break :blk buf else |_| allocator.free(buf);
            } else |_| {}
        }
        return error.InvalidClerkKey;
    };
    defer allocator.free(decoded);

    if (decoded.len == 0) return error.InvalidClerkKey;

    if (decoded[0] == '{') {
        const parsed = std.json.parseFromSlice(struct {
            issuer: []const u8,
        }, allocator, decoded, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidClerkKey,
        };
        defer parsed.deinit();
        return try allocator.dupe(u8, parsed.value.issuer);
    }

    // A real key: the host of the instance's Frontend API, then a `$` that
    // marks the end ("example.accounts.dev$"). The issuer of its tokens,
    // and the base of its addresses, is that host over https.
    const host = std.mem.trimEnd(u8, decoded, "$");
    if (host.len == 0) return error.InvalidClerkKey;
    if (std.mem.indexOf(u8, host, "://") != null) return try allocator.dupe(u8, host);
    return try std.fmt.allocPrint(allocator, "https://{s}", .{host});
}

test "parseIssuerUrl: a publishable key is the instance's host in base64, with a $ at the end" {
    const a = std.testing.allocator;

    // The example of Clerk's own documentation: "example.accounts.dev$".
    const dev = try parseIssuerUrl(a, "pk_test_ZXhhbXBsZS5hY2NvdW50cy5kZXYk");
    defer a.free(dev);
    try std.testing.expectEqualStrings("https://example.accounts.dev", dev);

    // A production key, and one whose base64 carries padding.
    const live = try parseIssuerUrl(a, "pk_live_Y2xlcmsuZXhhbXBsZS5jb20k");
    defer a.free(live);
    try std.testing.expectEqualStrings("https://clerk.example.com", live);
    const padded = try parseIssuerUrl(a, "pk_test_YS5iJA==");
    defer a.free(padded);
    try std.testing.expectEqualStrings("https://a.b", padded);

    // The JSON form the tests use (an issuer with its scheme) still works.
    const json = try parseIssuerUrl(a, "pk_test_eyJpc3N1ZXIiOiJodHRwOi8vMTI3LjAuMC4xOjkifQ");
    defer a.free(json);
    try std.testing.expectEqualStrings("http://127.0.0.1:9", json);

    try std.testing.expectError(error.InvalidClerkKey, parseIssuerUrl(a, "sk_test_ZXhhbXBsZQ"));
    try std.testing.expectError(error.InvalidClerkKey, parseIssuerUrl(a, "pk_test_"));
    try std.testing.expectError(error.InvalidClerkKey, parseIssuerUrl(a, "pk_test_JA")); // only the "$"
}
