//! Keycloak login (`spider.keycloak`): the OAuth authorization-code flow
//! against a realm, plus the middleware that checks the token on every request.
//! The token check itself is `spider.jwks`; this file adds the login, callback
//! and refresh routes and the cookies they set.

const std = @import("std");
const pacman = @import("pacman");
const Ctx = @import("../core/context.zig").Ctx;
const Response = @import("../core/context.zig").Response;
const MiddlewareFn = @import("../core/context.zig").MiddlewareFn;
const Handler = @import("../routing/router.zig").Handler;
const jwks = @import("jwks.zig");
const JwksAuth = jwks.JwksAuth;
const url_util = @import("../internal/url.zig");

/// What `Keycloak.init` takes. `fromEnv()` fills the connection settings from
/// the environment; set the other fields on the result.
pub const KeycloakConfig = struct {
    /// Address of the Keycloak server, without a trailing slash and without
    /// `/realms/...` (the issuer is `{base_url}/realms/{realm}`). `fromEnv`:
    /// KEYCLOAK_BASE_URL. No default.
    base_url: []const u8,
    /// The realm users log in to. `fromEnv`: KEYCLOAK_REALM. No default.
    realm: []const u8,
    /// The app's client in that realm. `fromEnv`: KEYCLOAK_CLIENT_ID. No
    /// default.
    client_id: []const u8,
    /// The client's secret, sent when a code or a refresh token is exchanged
    /// for tokens. `fromEnv`: KEYCLOAK_CLIENT_SECRET. No default.
    client_secret: []const u8,
    /// The full URL of the app's callback route, as registered in the client
    /// (the route `callbackHandler()` answers). `fromEnv`:
    /// KEYCLOAK_REDIRECT_URI.
    redirect_uri: []const u8 = "http://localhost:3000/auth/callback",
    /// Where a browser request without a token is redirected, and where a
    /// rejected callback or a failed refresh ends. Mount `loginHandler()`
    /// there.
    login_path: []const u8 = "/auth/login",
    /// Where the callback redirects once the cookies are set, and where a
    /// refresh goes when it has no usable `?next=`.
    after_callback_path: []const u8 = "/",
    /// Paths the middleware lets through without a token: the path itself and
    /// anything under it (`"/auth"` also covers `/auth/login`, not
    /// `/authors`). The login, callback and refresh routes must be listed, or
    /// be `.public`. Default: none.
    auth_skip_paths: []const []const u8 = &.{},
    /// Cookie that keeps the refresh token (HttpOnly, SameSite=Lax, 30 days;
    /// Secure unless `redirect_uri` is plain http, like every cookie set
    /// here: a browser drops a Secure cookie that arrives over http).
    refresh_cookie_name: []const u8 = "__refresh",
    /// Where a browser request with an expired token is redirected, as
    /// `{refresh_path}?next=<the request's target>`. Mount `refreshHandler()`
    /// there. htmx and SSE requests get 401 instead of the redirect.
    refresh_path: []const u8 = "/auth/refresh",
    /// true: a request without a valid token gets a 401 with a JSON body
    /// instead of a redirect.
    api_mode: bool = false,
    /// See JwksConfig.active_org_cookie.
    active_org_cookie: ?[]const u8 = null,
    /// Verify the OAuth `state` on the callback against a nonce cookie set by
    /// `authorize()` (login CSRF protection). Every flow that sends users to
    /// Keycloak must go through `authorize()`/`loginHandler()` for this to
    /// pass — a hand-built authorize URL has no matching cookie and its
    /// callback is rejected (redirected back to `login_path`).
    verify_state: bool = true,
    /// Cookie that keeps the nonce of `verify_state` (HttpOnly,
    /// SameSite=Lax, 10 minutes).
    state_cookie_name: []const u8 = "__oauth_state",
    /// Client whose tokens are accepted (see JwksConfig.audience); defaults
    /// to `client_id`, so a token another client of the realm obtained for
    /// the user (admin-cli, a partner app) is rejected.
    audience: ?[]const u8 = null,
    /// See JwksConfig.roles_claim (e.g. "resource_access.<client>.roles"
    /// for client roles instead of realm roles).
    roles_claim: ?[]const u8 = "realm_access.roles",
    /// See JwksConfig.org_claims.
    org_claims: jwks.OrgClaims = .phase_two,
    /// See JwksConfig.map_claims.
    map_claims: ?*const fn (c: *Ctx, claims: std.json.ObjectMap) anyerror!void = null,

    /// The connection settings from the environment — KEYCLOAK_BASE_URL,
    /// KEYCLOAK_REALM, KEYCLOAK_CLIENT_ID, KEYCLOAK_CLIENT_SECRET and
    /// KEYCLOAK_REDIRECT_URI (default http://localhost:3000/auth/callback);
    /// every other field keeps its default. One of the first four that is
    /// not set becomes an empty string, with no error here: `Keycloak.init`
    /// is what fails then. Adjust the result as needed:
    ///
    /// ```zig
    /// var cfg = spider.keycloak.KeycloakConfig.fromEnv();
    /// cfg.after_callback_path = "/auth/session";
    /// ```
    pub fn fromEnv() KeycloakConfig {
        const env = @import("../internal/env.zig");
        return .{
            .base_url = env.getOr("KEYCLOAK_BASE_URL", ""),
            .realm = env.getOr("KEYCLOAK_REALM", ""),
            .client_id = env.getOr("KEYCLOAK_CLIENT_ID", ""),
            .client_secret = env.getOr("KEYCLOAK_CLIENT_SECRET", ""),
            .redirect_uri = env.getOr("KEYCLOAK_REDIRECT_URI", "http://localhost:3000/auth/callback"),
        };
    }
};

/// Which Keycloak page `Keycloak.authorize` sends the user to.
pub const AuthorizeEndpoint = enum {
    /// Regular login page.
    auth,
    /// Keycloak's self-registration page.
    registrations,
};

/// Options of `Keycloak.authorize`.
pub const AuthorizeOptions = struct {
    /// The login page (default) or the registration page.
    endpoint: AuthorizeEndpoint = .auth,
    /// App data carried through the OAuth round-trip inside `state`. The
    /// callback understands "invite:<token>" and forwards it as
    /// `after_callback_path?invite=<token>`.
    payload: []const u8 = "",
    /// Sent as `kc_idp_hint` (e.g. "google") to skip Keycloak's own login form.
    idp_hint: ?[]const u8 = null,
};

const nonce_len = 32; // hex chars of a 16-byte random nonce

/// One Keycloak realm for the app: create it once at startup, add its
/// middleware and mount its three handlers.
///
/// ```zig
/// var kc = try spider.keycloak.Keycloak.init(allocator, io, spider.keycloak.KeycloakConfig.fromEnv());
/// defer kc.deinit();
/// server
///     .use(kc.middleware())
///     .get("/auth/login", kc.loginHandler(), .{ .public = true })
///     .get("/auth/callback", kc.callbackHandler(), .{ .public = true })
///     .get("/auth/refresh", kc.refreshHandler(), .{ .public = true });
/// ```
///
/// The middleware and the handlers keep a pointer to this value: it must not
/// move or be freed while the server runs. They also keep it in one static
/// slot each, so a process can use one Keycloak instance; a second one
/// replaces the first in every handler.
pub const Keycloak = struct {
    /// The token verifier (`spider.jwks.JwksAuth`) built from the config.
    jwks: JwksAuth,
    /// The config given to `init`. Its strings are not copied.
    config: KeycloakConfig,
    /// `{base_url}/realms/{realm}`: the `iss` every token must carry.
    issuer: []const u8,
    /// Owned here because JwksAuth keeps referencing it (re-fetch on an
    /// unknown `kid`), so it must live as long as the Keycloak instance.
    jwks_url: []const u8,
    // internal: frees `issuer` and `jwks_url` in deinit()
    allocator: std.mem.Allocator,

    /// Builds the issuer and downloads the realm's signing keys, so Keycloak
    /// must be reachable when the app starts: error.JwksFetchFailed when it
    /// does not answer with a key set, or the HTTP client's error when it
    /// cannot be reached. `config`'s strings are not copied: they must stay
    /// valid as long as the result.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: KeycloakConfig) !Keycloak {
        const issuer = try std.fmt.allocPrint(allocator, "{s}/realms/{s}", .{ config.base_url, config.realm });
        errdefer allocator.free(issuer);
        const jwks_url = try std.fmt.allocPrint(allocator, "{s}/protocol/openid-connect/certs", .{issuer});
        errdefer allocator.free(jwks_url);
        const jwks_auth = try JwksAuth.init(allocator, io, .{
            .jwks_url = jwks_url,
            .issuer = issuer,
            .audience = config.audience orelse config.client_id,
            .login_path = config.login_path,
            .after_callback_path = config.after_callback_path,
            .auth_skip_paths = config.auth_skip_paths,
            .refresh_path = config.refresh_path,
            .api_mode = config.api_mode,
            .active_org_cookie = config.active_org_cookie,
            .roles_claim = config.roles_claim,
            .org_claims = config.org_claims,
            .map_claims = config.map_claims,
        });
        return Keycloak{
            .jwks = jwks_auth,
            .config = config,
            .issuer = issuer,
            .jwks_url = jwks_url,
            .allocator = allocator,
        };
    }

    /// Frees the keys and the two URLs `init` allocated.
    pub fn deinit(self: *Keycloak) void {
        self.jwks.deinit();
        self.allocator.free(self.jwks_url);
        self.allocator.free(self.issuer);
    }

    /// The middleware that checks the token of every request (see
    /// `JwksAuth.middleware`): `server.use(kc.middleware())`.
    pub fn middleware(self: *Keycloak) MiddlewareFn {
        return self.jwks.middleware();
    }

    /// The login page URL with `state` (URL-encoded, like the client id and
    /// the redirect address; no state cookie is set). Allocated with the
    /// allocator given to `init`; the caller frees it. Prefer `authorize`:
    /// with `verify_state` on (the default), the callback of a login started
    /// from this URL is rejected.
    pub fn authUrl(self: *const Keycloak, state: []const u8) ![]u8 {
        const allocator = self.jwks.allocator;
        const client_id = try url_util.encodeQueryValue(allocator, self.config.client_id);
        defer allocator.free(client_id);
        const redirect_uri = try url_util.encodeQueryValue(allocator, self.config.redirect_uri);
        defer allocator.free(redirect_uri);
        const encoded_state = try url_util.encodeQueryValue(allocator, state);
        defer allocator.free(encoded_state);
        return try std.fmt.allocPrint(
            allocator,
            "{s}/protocol/openid-connect/auth?client_id={s}&redirect_uri={s}&response_type=code&scope=openid+email+profile&state={s}",
            .{ self.issuer, client_id, redirect_uri, encoded_state },
        );
    }

    /// Whether the cookies set here carry `Secure`: always, unless the app
    /// itself is reached over plain http (a developer's machine), where a
    /// browser would refuse to keep them.
    fn secureCookies(self: *const Keycloak) bool {
        return url_util.cookiesSecureFor(self.config.redirect_uri);
    }

    /// The handler for the login route: redirects to Keycloak's login page
    /// (`authorize` with the default options).
    pub fn loginHandler(self: *Keycloak) Handler {
        const S = struct {
            var instance: ?*Keycloak = null;
            fn h(c: *Ctx) anyerror!Response {
                return instance.?.loginFn(c);
            }
        };
        S.instance = self;
        return S.h;
    }

    /// The handler for the route named by `redirect_uri`. Checks `state`
    /// (when it fails: redirect to `login_path`), exchanges `code` for tokens,
    /// sets the `__session` cookie (the ID token, or the access token when
    /// there is none; 7 days) and the refresh cookie, then redirects to
    /// `after_callback_path` (with `?invite=<token>` for an "invite:<token>"
    /// payload). 400 without `code`; 502 when Keycloak returns no token. When
    /// Keycloak cannot be reached or its answer is not JSON, the handler
    /// returns that error (a 500 unless the app's `onError` says otherwise).
    pub fn callbackHandler(self: *Keycloak) Handler {
        const S = struct {
            var instance: ?*Keycloak = null;
            fn h(c: *Ctx) anyerror!Response {
                return instance.?.callbackFn(c);
            }
        };
        S.instance = self;
        return S.h;
    }

    /// The handler for `refresh_path`: trades the refresh cookie for new
    /// tokens, sets the cookies again and redirects to `?next=` when that is a
    /// local path, else to `after_callback_path`. Without a refresh cookie, or
    /// when Keycloak gives no token, it clears both cookies and redirects to
    /// `login_path`. When Keycloak cannot be reached, the handler returns the
    /// HTTP client's error.
    pub fn refreshHandler(self: *Keycloak) Handler {
        const S = struct {
            var instance: ?*Keycloak = null;
            fn h(c: *Ctx) anyerror!Response {
                return instance.?.refreshFn(c);
            }
        };
        S.instance = self;
        return S.h;
    }

    fn loginFn(self: *Keycloak, c: *Ctx) !Response {
        return self.authorize(c, .{});
    }

    /// Redirects the user to Keycloak with a fresh `state` whose nonce is also
    /// stored in a short-lived HttpOnly cookie, so `callbackHandler()` can tell
    /// its own round-trips from forged ones. Use this for every login,
    /// registration or IdP-hinted flow instead of hand-building the URL. The
    /// answer is a 302.
    pub fn authorize(self: *Keycloak, c: *Ctx, opts: AuthorizeOptions) !Response {
        var rand_buf: [nonce_len / 2]u8 = undefined;
        std.Io.random(c._io, &rand_buf);
        const nonce = std.fmt.bytesToHex(rand_buf, .lower);

        const state = if (opts.payload.len > 0)
            try std.fmt.allocPrint(c.arena, "{s}.{s}", .{ &nonce, opts.payload })
        else
            &nonce;

        var target: std.ArrayList(u8) = .empty;
        try target.print(c.arena, "{s}/protocol/openid-connect/{s}?client_id={s}&redirect_uri={s}&response_type=code&scope=openid+email+profile&state={s}", .{
            self.issuer,
            @tagName(opts.endpoint),
            try url_util.encodeQueryValue(c.arena, self.config.client_id),
            try url_util.encodeQueryValue(c.arena, self.config.redirect_uri),
            try url_util.encodeQueryValue(c.arena, state),
        });
        if (opts.idp_hint) |hint| {
            try target.print(c.arena, "&kc_idp_hint={s}", .{try url_util.encodeQueryValue(c.arena, hint)});
        }

        const state_cookie = try c.setCookie(self.config.state_cookie_name, &nonce, .{
            .http_only = true,
            .secure = self.secureCookies(),
            .same_site = "Lax",
            .path = "/",
            .max_age = 600,
        });
        const hdrs = try c.arena.alloc([2][]const u8, 2);
        hdrs[0] = .{ "Location", target.items };
        hdrs[1] = .{ "Set-Cookie", state_cookie };
        return Response{ .status = .found, .headers = hdrs };
    }

    /// Verifies the callback's `state` and returns the app payload it carried
    /// ("" when none), or null when the state is missing/forged/expired.
    fn checkState(self: *Keycloak, c: *Ctx) ?[]const u8 {
        const raw = c.query("state") orelse return if (self.config.verify_state) null else "";
        const state = url_util.decodeQueryValue(c.arena, raw) catch return null;
        if (!self.config.verify_state) return state;

        const nonce = state[0..@min(state.len, nonce_len)];
        if (nonce.len != nonce_len) return null;
        const payload = if (state.len == nonce_len)
            ""
        else if (state[nonce_len] == '.')
            state[nonce_len + 1 ..]
        else
            return null;

        const cookie_nonce = c.cookie(self.config.state_cookie_name) orelse return null;
        if (cookie_nonce.len != nonce_len) return null;
        if (!std.crypto.timing_safe.eql([nonce_len]u8, nonce[0..nonce_len].*, cookie_nonce[0..nonce_len].*)) return null;
        return payload;
    }

    fn clearStateCookie(self: *Keycloak, c: *Ctx) ![]const u8 {
        return c.setCookie(self.config.state_cookie_name, "", .{
            .http_only = true,
            .secure = self.secureCookies(),
            .same_site = "Lax",
            .path = "/",
            .max_age = 0,
        });
    }

    fn callbackFn(self: *Keycloak, c: *Ctx) !Response {
        const code = c.query("code") orelse
            return c.text("Missing authorization code", .{ .status = .bad_request });

        // Checked before talking to Keycloak: a forged or stale callback must
        // not be able to log the browser into someone else's account.
        const payload = self.checkState(c) orelse {
            std.log.warn("[keycloak] callback rejected: OAuth state missing or not matching the state cookie", .{});
            const hdrs = try c.arena.alloc([2][]const u8, 2);
            hdrs[0] = .{ "Location", self.config.login_path };
            hdrs[1] = .{ "Set-Cookie", try self.clearStateCookie(c) };
            return Response{ .status = .found, .headers = hdrs };
        };

        const token_url = try std.fmt.allocPrint(c.arena, "{s}/protocol/openid-connect/token", .{self.issuer});

        var res = try pacman.post(c._io, c.arena, token_url, .{
            .body = .{ .form = &.{
                .{ "grant_type", "authorization_code" },
                .{ "code", code },
                .{ "client_id", self.config.client_id },
                .{ "client_secret", self.config.client_secret },
                .{ "redirect_uri", self.config.redirect_uri },
            } },
        });
        defer res.deinit();

        const parsed = try res.json(struct {
            access_token: []const u8 = "",
            id_token: []const u8 = "",
            refresh_token: []const u8 = "",
        });
        defer parsed.deinit();

        const jwt = if (parsed.value.id_token.len > 0) parsed.value.id_token else parsed.value.access_token;
        if (jwt.len == 0)
            return c.text("No token received from Keycloak", .{ .status = .bad_gateway });

        const location = if (std.mem.startsWith(u8, payload, "invite:"))
            try std.fmt.allocPrint(c.arena, "{s}?invite={s}", .{
                self.config.after_callback_path,
                try url_util.encodeQueryValue(c.arena, payload["invite:".len..]),
            })
        else
            self.config.after_callback_path;

        var hdrs: std.ArrayList([2][]const u8) = .empty;
        try hdrs.append(c.arena, .{ "Location", location });
        try hdrs.append(c.arena, .{ "Set-Cookie", try c.setCookie("__session", jwt, .{
            .http_only = true,
            .secure = self.secureCookies(),
            .same_site = "Lax",
            .path = "/",
            .max_age = 86400 * 7,
        }) });
        if (parsed.value.refresh_token.len > 0) {
            try hdrs.append(c.arena, .{ "Set-Cookie", try c.setCookie(self.config.refresh_cookie_name, parsed.value.refresh_token, .{
                .http_only = true,
                .secure = self.secureCookies(),
                .same_site = "Lax",
                .path = "/",
                .max_age = 86400 * 30,
            }) });
        }
        if (self.config.verify_state) {
            try hdrs.append(c.arena, .{ "Set-Cookie", try self.clearStateCookie(c) });
        }
        return Response{ .status = .found, .headers = hdrs.items };
    }

    fn refreshFn(self: *Keycloak, c: *Ctx) !Response {
        const next = safeNext(c, self.config.after_callback_path);

        const refresh_token = c.cookie(self.config.refresh_cookie_name) orelse
            return self.redirectToLogin(c);

        const token_url = try std.fmt.allocPrint(c.arena, "{s}/protocol/openid-connect/token", .{self.issuer});

        var res = try pacman.post(c._io, c.arena, token_url, .{
            .body = .{ .form = &.{
                .{ "grant_type", "refresh_token" },
                .{ "refresh_token", refresh_token },
                .{ "client_id", self.config.client_id },
                .{ "client_secret", self.config.client_secret },
            } },
        });
        defer res.deinit();

        const parsed = res.json(struct {
            access_token: []const u8 = "",
            id_token: []const u8 = "",
            refresh_token: []const u8 = "",
        }) catch return self.redirectToLogin(c);
        defer parsed.deinit();

        const jwt = if (parsed.value.id_token.len > 0) parsed.value.id_token else parsed.value.access_token;
        if (jwt.len == 0) return self.redirectToLogin(c);

        const session_cookie = try c.setCookie("__session", jwt, .{
            .http_only = true,
            .secure = self.secureCookies(),
            .same_site = "Lax",
            .path = "/",
            .max_age = 86400 * 7,
        });

        if (parsed.value.refresh_token.len > 0) {
            const refresh_cookie = try c.setCookie(self.config.refresh_cookie_name, parsed.value.refresh_token, .{
                .http_only = true,
                .secure = self.secureCookies(),
                .same_site = "Lax",
                .path = "/",
                .max_age = 86400 * 30,
            });
            const hdrs = try c.arena.alloc([2][]const u8, 3);
            hdrs[0] = .{ "Location", next };
            hdrs[1] = .{ "Set-Cookie", session_cookie };
            hdrs[2] = .{ "Set-Cookie", refresh_cookie };
            return Response{ .status = .found, .headers = hdrs };
        }

        const hdrs = try c.arena.alloc([2][]const u8, 2);
        hdrs[0] = .{ "Location", next };
        hdrs[1] = .{ "Set-Cookie", session_cookie };
        return Response{ .status = .found, .headers = hdrs };
    }

    fn redirectToLogin(self: *Keycloak, c: *Ctx) !Response {
        const clear_session = try c.setCookie("__session", "", .{
            .http_only = true,
            .secure = self.secureCookies(),
            .same_site = "Lax",
            .path = "/",
            .max_age = 0,
        });
        const clear_refresh = try c.setCookie(self.config.refresh_cookie_name, "", .{
            .http_only = true,
            .secure = self.secureCookies(),
            .same_site = "Lax",
            .path = "/",
            .max_age = 0,
        });
        const hdrs = try c.arena.alloc([2][]const u8, 3);
        hdrs[0] = .{ "Location", self.config.login_path };
        hdrs[1] = .{ "Set-Cookie", clear_session };
        hdrs[2] = .{ "Set-Cookie", clear_refresh };
        return Response{ .status = .found, .headers = hdrs };
    }
};

/// The `?next=` destination for refresh, decoded and restricted to a local
/// path; anything else (other origins, "//host", control chars, malformed
/// encoding) falls back to `fallback` instead of becoming an open redirect.
fn safeNext(c: *Ctx, fallback: []const u8) []const u8 {
    const raw = c.query("next") orelse return fallback;
    const decoded = url_util.decodeQueryValue(c.arena, raw) catch return fallback;
    if (!url_util.isSafeLocalRedirect(decoded)) return fallback;
    return decoded;
}
