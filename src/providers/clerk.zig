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
    /// issuer and the JWKS URL are derived from it; it is also sent as the
    /// OAuth `client_id`. No default.
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
pub const Clerk = struct {
    /// The token verifier (`spider.jwks.JwksAuth`), with `.org_claims = .clerk`.
    jwks: JwksAuth,
    /// The config given to `init`. Its strings are not copied.
    config: ClerkConfig,
    /// The issuer decoded from the publishable key: the base of the JWKS and
    /// OAuth URLs.
    domain: []const u8,

    /// Decodes the issuer from the publishable key (error.InvalidClerkKey when
    /// it has no `pk_live_` / `pk_test_` prefix or decodes to nothing) and
    /// downloads the signing keys from `{issuer}/.well-known/jwks.json`:
    /// error.JwksFetchFailed when that does not answer with a key set.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: ClerkConfig) !Clerk {
        const domain = try parseIssuerUrl(allocator, config.publishable_key);
        const jwks_url = try std.fmt.allocPrint(allocator, "{s}/.well-known/jwks.json", .{domain});
        defer allocator.free(jwks_url);
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

    /// Frees the cached keys.
    pub fn deinit(self: *Clerk) void {
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
    /// `JwksAuth.middleware`): `server.use(clerk.middleware())`.
    pub fn middleware(self: *Clerk) MiddlewareFn {
        return self.jwks.middleware();
    }

    /// The handler for the route named by `redirect_uri`: exchanges `code`
    /// for tokens, sets the `__session` cookie (the ID token, or the access
    /// token when there is none; 7 days) and redirects to
    /// `after_callback_path`. 400 without `code`; 502 when Clerk returns no
    /// token. The OAuth `state` is not checked.
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

        return Response{
            .status = .found,
            .headers = &.{
                .{ "Location", self.config.after_callback_path },
                .{ "Set-Cookie", cookie_str },
            },
        };
    }
};

fn parseIssuerUrl(allocator: std.mem.Allocator, publishable_key: []const u8) ![]const u8 {
    const prefix = if (std.mem.startsWith(u8, publishable_key, "pk_live_"))
        "pk_live_"
    else if (std.mem.startsWith(u8, publishable_key, "pk_test_"))
        "pk_test_"
    else
        return error.InvalidClerkKey;

    const b64_data = publishable_key[prefix.len..];

    const decoded_len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(b64_data);
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded, b64_data);

    if (decoded.len == 0) return error.InvalidClerkKey;

    if (decoded[0] == '{') {
        const parsed = try std.json.parseFromSlice(struct {
            issuer: []const u8,
        }, allocator, decoded[0..decoded_len], .{});
        defer parsed.deinit();
        return try allocator.dupe(u8, parsed.value.issuer);
    }

    return try allocator.dupe(u8, decoded[0..decoded_len]);
}
