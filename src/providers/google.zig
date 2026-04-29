const std = @import("std");
const pacman = @import("pacman");
const Ctx = @import("../core/context.zig").Ctx;

pub const GoogleConfig = struct {
    client_id: []const u8,
    client_secret: []const u8,
    redirect_uri: []const u8,
};

pub const GoogleProfile = struct {
    id: []const u8,
    email: []const u8,
    name: []const u8,
    picture: []const u8,
};

pub fn authUrl(arena: std.mem.Allocator, config: GoogleConfig) ![]u8 {
    return std.fmt.allocPrint(
        arena,
        "https://accounts.google.com/o/oauth2/v2/auth" ++
            "?client_id={s}&redirect_uri={s}&response_type=code" ++
            "&scope=openid%20email%20profile&access_type=offline",
        .{ config.client_id, config.redirect_uri },
    );
}

// Profile is allocated in c.arena — freed automatically at end of request.
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
