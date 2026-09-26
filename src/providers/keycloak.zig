const std = @import("std");
const pacman = @import("pacman");
const Ctx = @import("../core/context.zig").Ctx;
const Response = @import("../core/context.zig").Response;
const MiddlewareFn = @import("../core/context.zig").MiddlewareFn;
const Handler = @import("../routing/router.zig").Handler;
const JwksAuth = @import("jwks.zig").JwksAuth;
const url_util = @import("../internal/url.zig");

pub const KeycloakConfig = struct {
    base_url: []const u8,
    realm: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    redirect_uri: []const u8 = "http://localhost:3000/auth/callback",
    login_path: []const u8 = "/auth/login",
    after_callback_path: []const u8 = "/",
    state_prefix: []const u8 = "",
    auth_skip_paths: []const []const u8 = &.{},
    refresh_cookie_name: []const u8 = "__refresh",
    refresh_path: []const u8 = "/auth/refresh",
    api_mode: bool = false,
    /// See JwksConfig.active_org_cookie.
    active_org_cookie: ?[]const u8 = null,
    /// Verify the OAuth `state` on the callback against a nonce cookie set by
    /// `authorize()` (login CSRF protection). Every flow that sends users to
    /// Keycloak must go through `authorize()`/`loginHandler()` for this to
    /// pass — a hand-built authorize URL has no matching cookie and its
    /// callback is rejected (redirected back to `login_path`).
    verify_state: bool = true,
    state_cookie_name: []const u8 = "__oauth_state",
    /// Client whose tokens are accepted (see JwksConfig.audience); defaults
    /// to `client_id`, so a token another client of the realm obtained for
    /// the user (admin-cli, a partner app) is rejected.
    audience: ?[]const u8 = null,
};

pub const AuthorizeEndpoint = enum {
    /// Regular login page.
    auth,
    /// Keycloak's self-registration page.
    registrations,
};

pub const AuthorizeOptions = struct {
    endpoint: AuthorizeEndpoint = .auth,
    /// App data carried through the OAuth round-trip inside `state`. The
    /// callback understands "invite:<token>" and forwards it as
    /// `after_callback_path?invite=<token>`.
    payload: []const u8 = "",
    /// Sent as `kc_idp_hint` (e.g. "google") to skip Keycloak's own login form.
    idp_hint: ?[]const u8 = null,
};

const nonce_len = 32; // hex chars of a 16-byte random nonce

pub const Keycloak = struct {
    jwks: JwksAuth,
    config: KeycloakConfig,
    issuer: []const u8,
    /// Owned here because JwksAuth keeps referencing it (re-fetch on an
    /// unknown `kid`), so it must live as long as the Keycloak instance.
    jwks_url: []const u8,
    allocator: std.mem.Allocator,

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
        });
        return Keycloak{
            .jwks = jwks_auth,
            .config = config,
            .issuer = issuer,
            .jwks_url = jwks_url,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Keycloak) void {
        self.jwks.deinit();
        self.allocator.free(self.jwks_url);
        self.allocator.free(self.issuer);
    }

    pub fn middleware(self: *Keycloak) MiddlewareFn {
        return self.jwks.middleware();
    }

    pub fn authUrl(self: *const Keycloak, state: []const u8) ![]u8 {
        return try std.fmt.allocPrint(
            self.jwks.allocator,
            "{s}/protocol/openid-connect/auth?client_id={s}&redirect_uri={s}&response_type=code&scope=openid+email+profile&state={s}",
            .{ self.issuer, self.config.client_id, self.config.redirect_uri, state },
        );
    }

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
    /// registration or IdP-hinted flow instead of hand-building the URL.
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
            .secure = true,
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
            .secure = true,
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
            .secure = true,
            .same_site = "Lax",
            .path = "/",
            .max_age = 86400 * 7,
        }) });
        if (parsed.value.refresh_token.len > 0) {
            try hdrs.append(c.arena, .{ "Set-Cookie", try c.setCookie(self.config.refresh_cookie_name, parsed.value.refresh_token, .{
                .http_only = true,
                .secure = true,
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
            .secure = true,
            .same_site = "Lax",
            .path = "/",
            .max_age = 86400 * 7,
        });

        if (parsed.value.refresh_token.len > 0) {
            const refresh_cookie = try c.setCookie(self.config.refresh_cookie_name, parsed.value.refresh_token, .{
                .http_only = true,
                .secure = true,
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
            .secure = true,
            .same_site = "Lax",
            .path = "/",
            .max_age = 0,
        });
        const clear_refresh = try c.setCookie(self.config.refresh_cookie_name, "", .{
            .http_only = true,
            .secure = true,
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
