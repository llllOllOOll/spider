const std = @import("std");
const auth_marker = @import("../modules/auth_marker.zig");
const pacman = @import("pacman");
const Ctx = @import("../core/context.zig").Ctx;
const Response = @import("../core/context.zig").Response;
const MiddlewareFn = @import("../core/context.zig").MiddlewareFn;
const NextFn = @import("../core/context.zig").NextFn;
const url_util = @import("../internal/url.zig");

const rsa = std.crypto.Certificate.rsa;
const b64 = std.base64.url_safe_no_pad;

const RealmAccess = struct {
    roles: []const []const u8 = &.{},
};

const JwkEntry = struct {
    n: []const u8,
    e: []const u8,
};

pub const JwksConfig = struct {
    jwks_url: []const u8,
    issuer: ?[]const u8 = null,
    /// The client this app accepts tokens for. A token passes when it was
    /// issued to it (`azp`) or is addressed to it (`aud` is it, or a list
    /// containing it); anything else — e.g. a token some other client of the
    /// same realm obtained for the user — fails with error.InvalidAudience.
    /// null skips the check (then any client of the issuer can log users in).
    audience: ?[]const u8 = null,
    cookie_name: []const u8 = "__session",
    login_path: []const u8 = "/login",
    after_callback_path: []const u8 = "/",
    auth_skip_paths: []const []const u8 = &.{},
    refresh_path: ?[]const u8 = null,
    api_mode: bool = false,
    /// Cookie holding the org the user picked (e.g. "orbitx_condo"). When
    /// present and naming an org the user belongs to, its value becomes
    /// `c.activeOrgId()`, so `org_roles` checks only count roles held in that
    /// org. A cookie for any other org is ignored (same as no cookie).
    active_org_cookie: ?[]const u8 = null,
    /// Minimum time between JWKS re-fetches triggered by tokens with an
    /// unknown `kid`. Bounds how often arbitrary requests can make us call the
    /// IdP (a forged kid would otherwise force one fetch per request). A real
    /// key rotation is still picked up on the first unknown kid after it.
    min_refetch_interval_ms: u64 = 30_000,
    /// Where the token carries the user's roles (what `.roles` checks): a
    /// claim name, or a dotted path into nested objects; the claim is a
    /// list of strings or one string. A name containing dots is first
    /// looked up whole. Defaults to Keycloak's realm roles. Others:
    ///   "roles"                           Entra ID app roles, custom tokens
    ///   "cognito:groups"                  AWS Cognito groups
    ///   "https://myapp.example/roles"     Auth0 (a namespaced custom claim)
    ///   "resource_access.my-client.roles" Keycloak client roles
    /// null: the token grants no roles.
    roles_claim: ?[]const u8 = "realm_access.roles",
    /// How the token carries organization memberships (what `.org_roles`
    /// checks). See OrgClaims.
    org_claims: OrgClaims = .phase_two,
    /// Called with the verified token's claims after the mapping above, to
    /// put anything else on the request with c.addRole / c.addOrgRole /
    /// c.setActiveOrg (permissions, groups, a tenant id...). Like Spring's
    /// JwtAuthenticationConverter. An error it returns is the request's
    /// (error.Forbidden: 403).
    map_claims: ?*const fn (c: *Ctx, claims: std.json.ObjectMap) anyerror!void = null,
};

pub const OrgClaims = enum {
    /// Keycloak with Phase Two organizations: an `organizations` claim,
    /// {"<org id>": {"name": "..", "roles": ["..", ..]}}; roles may also be
    /// a single string.
    phase_two,
    /// Clerk: the session's active organization, `o: {id, rol, slg}` (v2
    /// tokens) or `org_id` / `org_role` / `org_slug` (v1; the "org:" prefix
    /// of the role is dropped, so both give e.g. "admin"). It is also the
    /// active org (`c.activeOrgId()`).
    clerk,
    /// The token carries no organizations.
    none,
};

pub const Claims = struct {
    sub: []const u8,
    email: ?[]const u8 = null,
    name: ?[]const u8 = null,
    iss: ?[]const u8 = null,
    exp: i64,
    nbf: ?i64 = null,
    realm_access: ?RealmAccess = null,
    extra: std.StringHashMapUnmanaged([]const u8) = .{},
};

const KeyMap = std.StringHashMapUnmanaged(JwkEntry);

pub const JwksAuth = struct {
    config: JwksConfig,
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Read under `keys_lock` (shared); replaced wholesale under it (exclusive).
    keys: KeyMap,
    keys_lock: std.Io.RwLock = .init,
    /// Singleflight for re-fetches: only one fetch runs at a time, and callers
    /// that waited re-check the cache before fetching again.
    fetch_mutex: std.Io.Mutex = .init,
    /// Guarded by `fetch_mutex`.
    last_fetch: ?std.Io.Timestamp = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: JwksConfig) !JwksAuth {
        var self = JwksAuth{
            .config = config,
            .allocator = allocator,
            .io = io,
            .keys = .{},
        };
        try self.fetchJwksWith(io);
        self.last_fetch = std.Io.Timestamp.now(io, .awake);
        return self;
    }

    pub fn deinit(self: *JwksAuth) void {
        freeKeyMap(self.allocator, &self.keys);
    }

    fn freeKeyMap(allocator: std.mem.Allocator, map: *KeyMap) void {
        var iter = map.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*.n);
            allocator.free(entry.value_ptr.*.e);
        }
        map.deinit(allocator);
    }

    /// Re-downloads the key set. Safe to call concurrently with verification.
    pub fn fetchJwks(self: *JwksAuth) !void {
        return self.fetchJwksWith(self.io);
    }

    fn fetchJwksWith(self: *JwksAuth, io: std.Io) !void {
        var res = try pacman.get(io, self.allocator, self.config.jwks_url, .{});
        defer res.deinit();

        if (res.status != .ok) {
            std.debug.print(
                "[spider] JWKS fetch failed: status={s}, url={s}\n  body: {s}\n",
                .{ @tagName(res.status), self.config.jwks_url, res.body_text },
            );
            return error.JwksFetchFailed;
        }

        const parsed = res.json(struct {
            keys: []const struct {
                kid: []const u8,
                n: []const u8,
                e: []const u8,
            },
        }) catch |err| {
            std.debug.print(
                "[spider] JWKS response parse failed: {s}\n  url: {s}\n  body: {s}\n",
                .{ @errorName(err), self.config.jwks_url, res.body_text },
            );
            return error.JwksFetchFailed;
        };
        defer parsed.deinit();

        // Build the new set off to the side, then swap it in under the
        // exclusive lock. Readers copy what they need while holding the shared
        // lock, so nobody can still be using the old entries once it's freed.
        var fresh: KeyMap = .{};
        errdefer freeKeyMap(self.allocator, &fresh);
        for (parsed.value.keys) |key| {
            const kid = try self.allocator.dupe(u8, key.kid);
            errdefer self.allocator.free(kid);
            const n = try self.allocator.dupe(u8, key.n);
            errdefer self.allocator.free(n);
            const e = try self.allocator.dupe(u8, key.e);
            errdefer self.allocator.free(e);
            try fresh.put(self.allocator, kid, .{ .n = n, .e = e });
        }

        self.keys_lock.lockUncancelable(io);
        var old = self.keys;
        self.keys = fresh;
        self.keys_lock.unlock(io);
        freeKeyMap(self.allocator, &old);
    }

    /// Copies key `kid` into `arena` (null when unknown). The copy outlives
    /// any concurrent re-fetch that frees the cached entry.
    fn copyKey(self: *JwksAuth, io: std.Io, arena: std.mem.Allocator, kid: []const u8) !?JwkEntry {
        self.keys_lock.lockSharedUncancelable(io);
        defer self.keys_lock.unlockShared(io);
        const entry = self.keys.get(kid) orelse return null;
        return .{ .n = try arena.dupe(u8, entry.n), .e = try arena.dupe(u8, entry.e) };
    }

    /// Key for `kid`, re-fetching the JWKS at most once per
    /// `min_refetch_interval_ms` when it's unknown (e.g. after key rotation).
    fn resolveKey(self: *JwksAuth, io: std.Io, arena: std.mem.Allocator, kid: []const u8) !JwkEntry {
        if (try self.copyKey(io, arena, kid)) |k| return k;

        self.fetch_mutex.lockUncancelable(io);
        defer self.fetch_mutex.unlock(io);

        // Someone else may have fetched while we waited for the mutex.
        if (try self.copyKey(io, arena, kid)) |k| return k;

        const now = std.Io.Timestamp.now(io, .awake);
        if (self.last_fetch) |last| {
            const elapsed_ns = last.durationTo(now).nanoseconds;
            if (elapsed_ns < @as(i96, self.config.min_refetch_interval_ms) * std.time.ns_per_ms)
                return error.UnknownKey;
        }
        self.last_fetch = now;
        self.fetchJwksWith(io) catch |err| {
            std.log.warn("[spider] JWKS re-fetch for unknown kid failed: {s}", .{@errorName(err)});
            return error.UnknownKey;
        };
        return (try self.copyKey(io, arena, kid)) orelse error.UnknownKey;
    }

    pub fn verifyToken(self: *JwksAuth, allocator: std.mem.Allocator, token: []const u8) !Claims {
        return self.verifyTokenIo(self.io, allocator, token);
    }

    /// Same as verifyToken, using `io` (the request's) for locking and any
    /// JWKS re-fetch. `allocator` should be an arena: key copies live in it.
    pub fn verifyTokenIo(self: *JwksAuth, io: std.Io, allocator: std.mem.Allocator, token: []const u8) !Claims {
        const parts = splitToken(token) orelse return error.InvalidToken;

        const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parts.header, parts.payload });
        defer allocator.free(signing_input);

        const hdr_len = try b64.Decoder.calcSizeForSlice(parts.header);
        const hdr_buf = try allocator.alloc(u8, hdr_len);
        defer allocator.free(hdr_buf);
        try b64.Decoder.decode(hdr_buf, parts.header);

        const parsed_hdr = try std.json.parseFromSlice(struct {
            kid: []const u8 = "",
        }, allocator, hdr_buf[0..hdr_len], .{ .ignore_unknown_fields = true });
        defer parsed_hdr.deinit();

        const jwk = try self.resolveKey(io, allocator, parsed_hdr.value.kid);

        try verifyRsaSha256(parts.sig, signing_input, jwk.n, jwk.e);

        const payload_len = try b64.Decoder.calcSizeForSlice(parts.payload);
        const payload_buf = try allocator.alloc(u8, payload_len);
        defer allocator.free(payload_buf);
        try b64.Decoder.decode(payload_buf, parts.payload);

        const RawClaims = struct {
            sub: []const u8,
            exp: i64,
            nbf: ?i64 = null,
            iss: ?[]const u8 = null,
            email: ?[]const u8 = null,
            name: ?[]const u8 = null,
            realm_access: ?RealmAccess = null,
            aud: ?std.json.Value = null,
            azp: ?[]const u8 = null,
        };

        const parsed = try std.json.parseFromSlice(RawClaims, allocator, payload_buf[0..payload_len], .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        if (self.config.issuer) |expected_iss| {
            const actual_iss = parsed.value.iss orelse return error.MissingIssuer;
            if (!std.mem.eql(u8, actual_iss, expected_iss)) return error.InvalidIssuer;
        }
        if (self.config.audience) |expected| {
            if (!issuedFor(expected, parsed.value.aud, parsed.value.azp)) return error.InvalidAudience;
        }

        return Claims{
            .sub = try allocator.dupe(u8, parsed.value.sub),
            .email = if (parsed.value.email) |e| try allocator.dupe(u8, e) else null,
            .name = if (parsed.value.name) |n| try allocator.dupe(u8, n) else null,
            .iss = if (parsed.value.iss) |i| try allocator.dupe(u8, i) else null,
            .exp = parsed.value.exp,
            .nbf = parsed.value.nbf,
            .realm_access = if (parsed.value.realm_access) |ra| blk: {
                var roles_copy = try allocator.alloc([]const u8, ra.roles.len);
                for (ra.roles, 0..) |role, j| {
                    roles_copy[j] = try allocator.dupe(u8, role);
                }
                break :blk RealmAccess{ .roles = roles_copy };
            } else null,
        };
    }

    pub fn middleware(self: *JwksAuth) MiddlewareFn {
        const S = struct {
            var instance: ?*JwksAuth = null;
            fn mw(c: *Ctx, next: NextFn) anyerror!Response {
                return instance.?.middlewareFn(c, next);
            }
        };
        S.instance = self;
        auth_marker.mark(S.mw);
        return S.mw;
    }

    fn middlewareFn(self: *JwksAuth, c: *Ctx, next: NextFn) !Response {
        const full_path = c.getPath();
        const path = if (std.mem.indexOfScalar(u8, full_path, '?')) |q|
            full_path[0..q]
        else
            full_path;
        if (c.route().public) return next(c);
        for (self.config.auth_skip_paths) |skip| {
            if (std.mem.eql(u8, path, skip) or
                (std.mem.startsWith(u8, path, skip) and
                    (path.len == skip.len or path[skip.len] == '/' or path[skip.len] == '?')))
                return next(c);
        }

        const token = extractToken(c, self.config.cookie_name) orelse {
            if (self.config.api_mode) {
                return c.json(.{ .@"error" = "unauthorized", .message = "Bearer token required" }, .{ .status = .unauthorized });
            }
            return redirect(c, self.config.login_path);
        };

        const claims = self.verifyTokenIo(c._io, c.arena, token) catch |err| switch (err) {
            error.InvalidToken,
            error.UnknownKey,
            error.InvalidIssuer,
            error.MissingIssuer,
            error.InvalidAudience,
            error.UnsupportedKeySize,
            error.InvalidSignature,
            => {
                if (self.config.api_mode) {
                    return c.json(.{ .@"error" = "unauthorized", .message = @errorName(err) }, .{ .status = .unauthorized });
                }
                return c.text(@errorName(err), .{ .status = .unauthorized });
            },
            else => |e| {
                if (self.config.api_mode) {
                    return c.json(.{ .@"error" = "unauthorized", .message = @errorName(e) }, .{ .status = .unauthorized });
                }
                return c.text(@errorName(e), .{ .status = .unauthorized });
            },
        };

        const now_sec: i64 = @intCast(@divFloor(
            std.Io.Clock.now(.real, c._io).nanoseconds,
            1_000_000_000,
        ));
        if (claims.exp < now_sec) {
            if (self.config.api_mode) {
                return c.json(.{ .@"error" = "unauthorized", .message = "Token expired" }, .{ .status = .unauthorized });
            }
            if (self.config.refresh_path) |rpath| {
                // HTMX and SSE requests must receive 401 — a 302 on HTMX loses the
                // original method/body, and on SSE it triggers competing OAuth flows
                // from each connection. The client JS handles the redirect centrally.
                const is_sse = std.mem.eql(u8, c.header("Accept") orelse "", "text/event-stream");
                if (c.isHtmx() or is_sse) return c.text("Token expired", .{ .status = .unauthorized });
                // Full target (path + query), encoded as ONE value so e.g.
                // "/tickets?tab=x&page=2" survives the round-trip intact.
                const refresh_url = try std.fmt.allocPrint(c.arena, "{s}?next={s}", .{ rpath, try url_util.encodeQueryValue(c.arena, full_path) });
                return redirect(c, refresh_url);
            }
            return c.text("Token expired", .{ .status = .unauthorized });
        }
        if (claims.nbf) |nbf| {
            if (nbf > now_sec)
                return c.text("Token not yet valid", .{ .status = .unauthorized });
        }

        try c.params.put(c.arena, try c.arena.dupe(u8, "_auth_sub"), try c.arena.dupe(u8, claims.sub));
        if (claims.email) |email| {
            try c.params.put(c.arena, try c.arena.dupe(u8, "_auth_email"), try c.arena.dupe(u8, email));
        }
        if (claims.name) |name| {
            try c.params.put(c.arena, try c.arena.dupe(u8, "_auth_name"), try c.arena.dupe(u8, name));
        }
        if (claims.iss) |iss| {
            try c.params.put(c.arena, try c.arena.dupe(u8, "_auth_iss"), try c.arena.dupe(u8, iss));
        }

        // The signature was checked above; decoding again can't fail for a
        // token that got here, but a failure just means no roles.
        if (decodePayload(c.arena, token)) |payload| {
            try applyClaims(c, self.config, payload);
        } else |_| {}
        if (self.config.active_org_cookie) |name| {
            if (c.cookie(name)) |org_id| {
                // Only honored for an org the token says the user belongs to.
                // A stale cookie (the user left that org) or a forged one is
                // ignored, falling back to "no active org" (any org) instead
                // of locking the user out of every org_roles route.
                if (org_id.len > 0 and c.isOrgMember(org_id)) try c.setActiveOrg(org_id);
            }
        }

        return next(c);
    }
};

fn decodePayload(arena: std.mem.Allocator, token: []const u8) !std.json.ObjectMap {
    const parts = splitToken(token) orelse return error.InvalidToken;
    const buf = try arena.alloc(u8, try b64.Decoder.calcSizeForSlice(parts.payload));
    try b64.Decoder.decode(buf, parts.payload);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, buf, .{});
    if (v != .object) return error.InvalidToken;
    return v.object;
}

/// Puts the token's roles and organizations on the request, as configured
/// (roles_claim, org_claims), then runs map_claims.
pub fn applyClaims(c: *Ctx, config: JwksConfig, claims: std.json.ObjectMap) !void {
    if (config.roles_claim) |path| {
        if (claimAt(claims, path)) |v| switch (v) {
            .string => |s| try c.addRole(s),
            .array => |list| {
                // Present but empty still says "no roles" (count 0).
                if (list.items.len == 0) try c.setRoles(&.{});
                for (list.items) |item| if (item == .string) try c.addRole(item.string);
            },
            else => {},
        };
    }
    switch (config.org_claims) {
        .phase_two => try phaseTwoOrgs(c, claims),
        .clerk => try clerkOrg(c, claims),
        .none => {},
    }
    if (config.map_claims) |f| try f(c, claims);
}

/// `path` as one claim name, else as a dotted path through nested objects.
fn claimAt(claims: std.json.ObjectMap, path: []const u8) ?std.json.Value {
    if (claims.get(path)) |v| return v;
    var cur: std.json.Value = .{ .object = claims };
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |seg| {
        if (cur != .object) return null;
        cur = cur.object.get(seg) orelse return null;
    }
    return cur;
}

fn phaseTwoOrgs(c: *Ctx, claims: std.json.ObjectMap) !void {
    const orgs = claims.get("organizations") orelse return;
    if (orgs != .object) return;
    if (c.params.get("_auth_orgs_count") == null) try c.params.put(c.arena, "_auth_orgs_count", "0");
    var it = orgs.object.iterator();
    while (it.next()) |entry| {
        const org = entry.value_ptr.*;
        if (org != .object) continue;
        const name = org.object.get("name") orelse continue;
        if (name != .string) continue;
        const roles_val = org.object.get("roles") orelse continue;
        const ref: Ctx.OrgRole = .{ .org_id = entry.key_ptr.*, .org_name = name.string, .role = undefined };
        switch (roles_val) {
            .string => |s| try c.addOrgRole(withRole(ref, s)),
            .array => |arr| for (arr.items) |r| {
                if (r == .string) try c.addOrgRole(withRole(ref, r.string));
            },
            else => {},
        }
    }
}

fn withRole(ref: Ctx.OrgRole, role: []const u8) Ctx.OrgRole {
    var r = ref;
    r.role = role;
    return r;
}

fn clerkOrg(c: *Ctx, claims: std.json.ObjectMap) !void {
    var id: ?[]const u8 = null;
    var role: ?[]const u8 = null;
    var slug: []const u8 = "";
    if (claims.get("o")) |o| {
        if (o == .object) {
            id = stringField(o.object, "id");
            role = stringField(o.object, "rol");
            slug = stringField(o.object, "slg") orelse "";
        }
    } else {
        id = stringField(claims, "org_id");
        role = stringField(claims, "org_role");
        slug = stringField(claims, "org_slug") orelse "";
    }
    const org_id = id orelse return;
    const r = role orelse return;
    const bare = if (std.mem.startsWith(u8, r, "org:")) r["org:".len..] else r;
    try c.addOrgRole(.{ .org_id = org_id, .org_name = slug, .role = bare });
    try c.setActiveOrg(org_id);
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn redirect(c: *Ctx, url: []const u8) Response {
    const headers = c.arena.alloc([2][]const u8, 1) catch
        return Response{ .status = .found, .body = url, .content_type = "text/plain" };
    headers[0] = .{ "Location", url };
    return Response{ .status = .found, .body = null, .content_type = "text/plain", .headers = headers };
}

fn extractToken(c: *Ctx, cookie_name: []const u8) ?[]const u8 {
    if (c.header("Authorization")) |auth| {
        if (std.mem.startsWith(u8, auth, "Bearer ")) {
            return auth["Bearer ".len..];
        }
    }
    return c.cookie(cookie_name);
}

fn splitToken(token: []const u8) ?struct { header: []const u8, payload: []const u8, sig: []const u8 } {
    var it = std.mem.splitScalar(u8, token, '.');
    const header = it.next() orelse return null;
    const payload = it.next() orelse return null;
    const sig = it.next() orelse return null;
    if (it.next() != null) return null;
    return .{ .header = header, .payload = payload, .sig = sig };
}

fn verifyRsaSha256(sig_b64url: []const u8, msg: []const u8, n_b64url: []const u8, e_b64url: []const u8) !void {
    const aa = std.heap.page_allocator;

    const sig_len = try b64.Decoder.calcSizeForSlice(sig_b64url);
    const sig_buf = try aa.alloc(u8, sig_len);
    defer aa.free(sig_buf);
    try b64.Decoder.decode(sig_buf, sig_b64url);

    const n_len = try b64.Decoder.calcSizeForSlice(n_b64url);
    const n_buf = try aa.alloc(u8, n_len);
    defer aa.free(n_buf);
    try b64.Decoder.decode(n_buf, n_b64url);

    const e_len = try b64.Decoder.calcSizeForSlice(e_b64url);
    const e_buf = try aa.alloc(u8, e_len);
    defer aa.free(e_buf);
    try b64.Decoder.decode(e_buf, e_b64url);

    try verifyRsaSha256Raw(sig_buf[0..sig_len], msg, n_buf[0..n_len], e_buf[0..e_len]);
}

/// OIDC client check: issued to `client` (azp), or addressed to it (aud as
/// a string or as a list).
fn issuedFor(client: []const u8, aud: ?std.json.Value, azp: ?[]const u8) bool {
    if (azp) |p| if (std.mem.eql(u8, p, client)) return true;
    const a = aud orelse return false;
    switch (a) {
        .string => |s| return std.mem.eql(u8, s, client),
        .array => |list| for (list.items) |item| {
            if (item == .string and std.mem.eql(u8, item.string, client)) return true;
        },
        else => {},
    }
    return false;
}

test "issuedFor: azp or aud must name the client" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try std.json.parseFromSliceLeaky(std.json.Value, a, "[\"account\",\"app\"]", .{});
    const other = try std.json.parseFromSliceLeaky(std.json.Value, a, "[\"account\"]", .{});
    try t.expect(issuedFor("app", .{ .string = "account" }, "app"));
    try t.expect(issuedFor("app", .{ .string = "app" }, "gateway"));
    try t.expect(issuedFor("app", list, "gateway"));
    try t.expect(!issuedFor("app", other, "admin-cli"));
    try t.expect(!issuedFor("app", .{ .string = "account" }, "admin-cli"));
    try t.expect(!issuedFor("app", null, null));
    try t.expect(!issuedFor("app", .{ .integer = 1 }, null));
}

fn verifyRsaSha256Raw(sig: []const u8, msg: []const u8, n: []const u8, e: []const u8) !void {
    const public_key = try rsa.PublicKey.fromBytes(e, n);
    switch (sig.len) {
        inline 128, 256, 384, 512 => |modulus_len| {
            var sig_arr: [modulus_len]u8 = undefined;
            @memcpy(&sig_arr, sig[0..modulus_len]);
            try rsa.PKCS1v1_5Signature.verify(modulus_len, sig_arr, msg, public_key, std.crypto.hash.sha2.Sha256);
        },
        else => return error.UnsupportedKeySize,
    }
}

fn testCtx(a: std.mem.Allocator) Ctx {
    return Ctx{ .request = undefined, .arena = a, .params = .{}, .body = null };
}

fn testClaims(c: *Ctx, config: JwksConfig, json: []const u8) !void {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, c.arena, json, .{});
    try applyClaims(c, config, v.object);
}

const test_cfg: JwksConfig = .{ .jwks_url = "" };

test "applyClaims: Keycloak token (default config) gives the same _auth_* params as before" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = testCtx(arena.allocator());
    try testClaims(&c, test_cfg,
        \\{"sub":"u1","realm_access":{"roles":["staff","offline_access"]},
        \\ "organizations":{"c1":{"name":"Tower A","roles":["admin","sindico"]},"c2":{"name":"Tower B","roles":"resident"}}}
    );
    const p = c.params;
    try std.testing.expectEqualStrings("2", p.get("_auth_roles_count").?);
    try std.testing.expectEqualStrings("staff", p.get("_auth_role_0").?);
    try std.testing.expectEqualStrings("offline_access", p.get("_auth_role_1").?);
    try std.testing.expectEqualStrings("3", p.get("_auth_orgs_count").?);
    try std.testing.expectEqualStrings("c1", p.get("_auth_org_0_id").?);
    try std.testing.expectEqualStrings("Tower A", p.get("_auth_org_0_name").?);
    try std.testing.expectEqualStrings("admin", p.get("_auth_org_0_role").?);
    try std.testing.expectEqualStrings("sindico", p.get("_auth_org_1_role").?);
    try std.testing.expectEqualStrings("c2", p.get("_auth_org_2_id").?);
    try std.testing.expectEqualStrings("resident", p.get("_auth_org_2_role").?);
}

test "applyClaims: an empty organizations claim still sets the count to 0; no claims set nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c = testCtx(arena.allocator());
    try testClaims(&c, test_cfg, "{\"sub\":\"u1\",\"organizations\":{}}");
    try std.testing.expectEqualStrings("0", c.params.get("_auth_orgs_count").?);
    var none = testCtx(arena.allocator());
    try testClaims(&none, test_cfg, "{\"sub\":\"u1\"}");
    try std.testing.expectEqual(@as(usize, 0), none.params.count());
}

test "applyClaims: roles_claim reads other providers' role claims" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        // Cognito groups (a colon, no nesting)
        .{ "cognito:groups", "{\"sub\":\"u\",\"cognito:groups\":[\"admins\"]}", "admins" },
        // Auth0 namespaced claim: a name with dots, matched whole
        .{ "https://app.example.com/roles", "{\"sub\":\"u\",\"https://app.example.com/roles\":[\"editor\"]}", "editor" },
        // Keycloak client roles (a nested path)
        .{ "resource_access.web.roles", "{\"sub\":\"u\",\"resource_access\":{\"web\":{\"roles\":[\"billing\"]}}}", "billing" },
        // A single role as a string
        .{ "role", "{\"sub\":\"u\",\"role\":\"owner\"}", "owner" },
    };
    for (cases) |case| {
        var c = testCtx(a);
        var cfg = test_cfg;
        cfg.roles_claim = case[0];
        try testClaims(&c, cfg, case[1]);
        try std.testing.expect(c.hasRole(case[2]));
        try std.testing.expectEqual(@as(usize, 1), (try c.roles()).len);
    }
    var off = testCtx(a);
    var cfg = test_cfg;
    cfg.roles_claim = null;
    try testClaims(&off, cfg, "{\"sub\":\"u\",\"realm_access\":{\"roles\":[\"staff\"]}}");
    try std.testing.expect(!off.hasRole("staff"));
}

test "applyClaims: Clerk org claims (v2 `o`, v1 org_*) become the active org's role" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = test_cfg;
    cfg.org_claims = .clerk;
    const tokens = [_][]const u8{
        "{\"sub\":\"u\",\"v\":2,\"o\":{\"id\":\"org_1\",\"rol\":\"admin\",\"slg\":\"acme\"}}",
        "{\"sub\":\"u\",\"org_id\":\"org_1\",\"org_role\":\"org:admin\",\"org_slug\":\"acme\"}",
    };
    for (tokens) |tok| {
        var c = testCtx(a);
        try testClaims(&c, cfg, tok);
        try std.testing.expectEqualStrings("org_1", c.activeOrgId().?);
        try std.testing.expectEqualStrings("acme", c.params.get("_auth_org_0_name").?);
        try std.testing.expect(c.hasActiveOrgRole("admin"));
    }
    var personal = testCtx(a);
    try testClaims(&personal, cfg, "{\"sub\":\"u\",\"v\":2}");
    try std.testing.expect(personal.activeOrgId() == null);
}

fn mapPermissions(c: *Ctx, claims: std.json.ObjectMap) anyerror!void {
    const perms = claims.get("permissions") orelse return;
    for (perms.array.items) |p| try c.addRole(p.string);
    if (claims.get("tenant")) |t| try c.addOrgRole(.{ .org_id = t.string, .role = "member" });
}

fn rejectAll(c: *Ctx, claims: std.json.ObjectMap) anyerror!void {
    _ = c;
    _ = claims;
    return error.Forbidden;
}

test "applyClaims: map_claims runs after the built-in mapping; its error is the request's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = test_cfg;
    cfg.map_claims = mapPermissions;
    var c = testCtx(arena.allocator());
    try testClaims(&c, cfg, "{\"sub\":\"u\",\"realm_access\":{\"roles\":[\"staff\"]},\"permissions\":[\"posts:write\"],\"tenant\":\"t9\"}");
    try std.testing.expect(c.hasRole("staff") and c.hasRole("posts:write"));
    try std.testing.expect(c.isOrgMember("t9"));
    cfg.map_claims = rejectAll;
    var d = testCtx(arena.allocator());
    try std.testing.expectError(error.Forbidden, testClaims(&d, cfg, "{\"sub\":\"u\"}"));
}
