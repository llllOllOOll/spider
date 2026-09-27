const std = @import("std");
const pacman = @import("pacman");
const Ctx = @import("../core/context.zig").Ctx;
const Response = @import("../core/context.zig").Response;
const MiddlewareFn = @import("../core/context.zig").MiddlewareFn;
const Handler = @import("../routing/router.zig").Handler;
const jwks = @import("jwks.zig");
const JwksAuth = jwks.JwksAuth;

pub const ClerkConfig = struct {
    publishable_key: []const u8,
    secret_key: []const u8,
    redirect_uri: []const u8 = "http://localhost:3000/auth/callback",
    login_path: []const u8 = "/login",
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

pub const Clerk = struct {
    jwks: JwksAuth,
    config: ClerkConfig,
    domain: []const u8,

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

    pub fn deinit(self: *Clerk) void {
        self.jwks.deinit();
    }

    pub fn authUrl(self: *const Clerk, arena: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            arena,
            "{s}/oauth/authorize?response_type=code&client_id={s}&redirect_uri={s}",
            .{ self.domain, self.config.publishable_key, self.config.redirect_uri },
        );
    }

    pub fn middleware(self: *Clerk) MiddlewareFn {
        return self.jwks.middleware();
    }

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
