const std = @import("std");
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

        if (claims.realm_access) |ra| {
            for (ra.roles, 0..) |role, i| {
                const key = try std.fmt.allocPrint(c.arena, "_auth_role_{d}", .{i});
                try c.params.put(c.arena, key, try c.arena.dupe(u8, role));
            }
            const count_str = try std.fmt.allocPrint(c.arena, "{d}", .{ra.roles.len});
            try c.params.put(c.arena, "_auth_roles_count", count_str);
        }

        if (extractToken(c, self.config.cookie_name)) |extracted| {
            injectOrganizations(c, extracted) catch {};
        }
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

fn injectOrganizations(c: *Ctx, token: []const u8) !void {
    // Split JWT para re-decodificar o payload
    var it = std.mem.splitScalar(u8, token, '.');
    _ = it.next() orelse return; // skip header
    const payload_b64 = it.next() orelse return;

    const payload_len = try b64.Decoder.calcSizeForSlice(payload_b64);
    const payload_buf = try c.arena.alloc(u8, payload_len);
    try b64.Decoder.decode(payload_buf, payload_b64);

    const parsed = try std.json.parseFromSlice(std.json.Value, c.arena, payload_buf[0..payload_len], .{});
    defer parsed.deinit();

    const orgs = parsed.value.object.get("organizations") orelse return;

    var i: usize = 0;
    var org_iter = orgs.object.iterator();
    while (org_iter.next()) |entry| {
        const org_id = entry.key_ptr.*;
        const org_val = entry.value_ptr.*;

        const org_name = org_val.object.get("name") orelse continue;
        const roles_val = org_val.object.get("roles") orelse continue;

        switch (roles_val) {
            .string => |s| {
                const id_key = try std.fmt.allocPrint(c.arena, "_auth_org_{d}_id", .{i});
                try c.params.put(c.arena, id_key, try c.arena.dupe(u8, org_id));
                const name_key = try std.fmt.allocPrint(c.arena, "_auth_org_{d}_name", .{i});
                try c.params.put(c.arena, name_key, try c.arena.dupe(u8, org_name.string));
                const role_key = try std.fmt.allocPrint(c.arena, "_auth_org_{d}_role", .{i});
                try c.params.put(c.arena, role_key, try c.arena.dupe(u8, s));
                i += 1;
            },
            .array => |arr| {
                for (arr.items) |role_val| {
                    const role = switch (role_val) {
                        .string => |s| s,
                        else => continue,
                    };
                    const id_key = try std.fmt.allocPrint(c.arena, "_auth_org_{d}_id", .{i});
                    try c.params.put(c.arena, id_key, try c.arena.dupe(u8, org_id));
                    const name_key = try std.fmt.allocPrint(c.arena, "_auth_org_{d}_name", .{i});
                    try c.params.put(c.arena, name_key, try c.arena.dupe(u8, org_name.string));
                    const role_key = try std.fmt.allocPrint(c.arena, "_auth_org_{d}_role", .{i});
                    try c.params.put(c.arena, role_key, try c.arena.dupe(u8, role));
                    i += 1;
                }
            },
            else => continue,
        }
    }

    const count_str = try std.fmt.allocPrint(c.arena, "{d}", .{i});
    try c.params.put(c.arena, "_auth_orgs_count", count_str);
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
