const std = @import("std");
const http_client = @import("../http_client.zig");

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
    return std.fmt.allocPrint(alloc,
        "https://accounts.google.com/o/oauth2/v2/auth" ++
        "?client_id={s}&redirect_uri={s}&response_type=code" ++
        "&scope=openid%20email%20profile&access_type=offline",
        .{ config.client_id, config.redirect_uri },
    );
}

pub fn fetchProfile(alloc: std.mem.Allocator, io: std.Io, code: []const u8, config: GoogleConfig) !GoogleProfile {
    const token_body = try std.fmt.allocPrint(alloc,
        "code={s}&client_id={s}&client_secret={s}&redirect_uri={s}&grant_type=authorization_code",
        .{ code, config.client_id, config.client_secret, config.redirect_uri },
    );
    defer alloc.free(token_body);

    const token_resp = try http_client.post(alloc, io,
        "https://oauth2.googleapis.com/token",
        token_body,
        "application/x-www-form-urlencoded",
    );
    defer alloc.free(token_resp);

    const TokenResponse = struct { access_token: []const u8 };
    const parsed_token = try std.json.parseFromSlice(TokenResponse, alloc, token_resp, .{ .ignore_unknown_fields = true });
    defer parsed_token.deinit();

    const bearer = try std.fmt.allocPrint(alloc, "Bearer {s}", .{parsed_token.value.access_token});
    defer alloc.free(bearer);

    const headers = [_]std.http.Header{.{ .name = "Authorization", .value = bearer }};
    const profile_resp = try http_client.get(alloc, io,
        "https://www.googleapis.com/oauth2/v2/userinfo",
        &headers,
    );
    defer alloc.free(profile_resp);

    const RawProfile = struct {
        id: []const u8,
        email: []const u8,
        name: []const u8,
        picture: []const u8,
    };
    const parsed = try std.json.parseFromSlice(RawProfile, alloc, profile_resp, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    return GoogleProfile{
        .id      = try alloc.dupe(u8, parsed.value.id),
        .email   = try alloc.dupe(u8, parsed.value.email),
        .name    = try alloc.dupe(u8, parsed.value.name),
        .picture = try alloc.dupe(u8, parsed.value.picture),
    };
}

pub fn deinitProfile(alloc: std.mem.Allocator, profile: GoogleProfile) void {
    alloc.free(profile.id);
    alloc.free(profile.email);
    alloc.free(profile.name);
    alloc.free(profile.picture);
}
