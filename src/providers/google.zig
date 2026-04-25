const std = @import("std");
const pacman = @import("pacman");

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

pub fn authUrl(alloc: std.mem.Allocator, config: GoogleConfig) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "https://accounts.google.com/o/oauth2/v2/auth" ++
            "?client_id={s}&redirect_uri={s}&response_type=code" ++
            "&scope=openid%20email%20profile&access_type=offline",
        .{ config.client_id, config.redirect_uri },
    );
}

pub fn fetchProfile(alloc: std.mem.Allocator, io: std.Io, code: []const u8, config: GoogleConfig) !GoogleProfile {
    // Request access token
    var token_res = try pacman.post(io, alloc, "https://oauth2.googleapis.com/token", .{
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

    // Request user profile
    var profile_res = try pacman.get(io, alloc, "https://www.googleapis.com/oauth2/v2/userinfo", .{
        .headers = &.{.{ .name = "Authorization", .value = try std.fmt.allocPrint(alloc, "Bearer {s}", .{parsed_token.value.access_token}) }},
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
        .id = try alloc.dupe(u8, parsed_profile.value.id),
        .email = try alloc.dupe(u8, parsed_profile.value.email),
        .name = try alloc.dupe(u8, parsed_profile.value.name),
        .picture = try alloc.dupe(u8, parsed_profile.value.picture),
    };
}

pub fn deinitProfile(alloc: std.mem.Allocator, profile: GoogleProfile) void {
    alloc.free(profile.id);
    alloc.free(profile.email);
    alloc.free(profile.name);
    alloc.free(profile.picture);
}
