const std = @import("std");
const web = @import("../web.zig");
const auth = @import("../auth.zig");
const http = @import("../http_client.zig");

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
    const token_body = try std.fmt.allocPrint(
        alloc,
        "code={s}&client_id={s}&client_secret={s}&redirect_uri={s}&grant_type=authorization_code",
        .{ code, config.client_id, config.client_secret, config.redirect_uri },
    );
    defer alloc.free(token_body);

    const token_resp = try httpPost(
        alloc,
        io,
        "https://oauth2.googleapis.com/token",
        token_body,
        "application/x-www-form-urlencoded",
    );
    defer alloc.free(token_resp);

    const TokenResponse = struct {
        access_token: []const u8,
    };
    const parsed_token = try std.json.parseFromSlice(TokenResponse, alloc, token_resp, .{ .ignore_unknown_fields = true });
    defer parsed_token.deinit();

    const bearer = try std.fmt.allocPrint(alloc, "Bearer {s}", .{parsed_token.value.access_token});
    defer alloc.free(bearer);

    const headers = [_]std.http.Header{.{ .name = "Authorization", .value = bearer }};
    const profile_resp = try httpGet(
        alloc,
        io,
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
        .id = try alloc.dupe(u8, parsed.value.id),
        .email = try alloc.dupe(u8, parsed.value.email),
        .name = try alloc.dupe(u8, parsed.value.name),
        .picture = try alloc.dupe(u8, parsed.value.picture),
    };
}

pub fn deinitProfile(alloc: std.mem.Allocator, profile: GoogleProfile) void {
    alloc.free(profile.id);
    alloc.free(profile.email);
    alloc.free(profile.name);
    alloc.free(profile.picture);
}

fn httpGet(alloc: std.mem.Allocator, io: std.Io, url: []const u8, headers: []const std.http.Header) ![]u8 {
    var client = std.http.Client{ .allocator = alloc, .io = io };
    defer client.deinit();
    var body = std.ArrayList(u8).init(alloc);
    defer body.deinit();
    const result = try client.fetch(.{
        .method = .GET,
        .location = .{ .url = url },
        .extra_headers = headers,
        .response_storage = .{ .dynamic = &body },
    });
    if (result.status != .ok) return error.BadStatus;
    return body.toOwnedSlice();
}

fn httpPost(alloc: std.mem.Allocator, io: std.Io, url: []const u8, body_str: []const u8, content_type: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = alloc, .io = io };
    defer client.deinit();
    var body = std.ArrayList(u8).init(alloc);
    defer body.deinit();
    const headers = [_]std.http.Header{.{ .name = "Content-Type", .value = content_type }};
    const result = try client.fetch(.{
        .method = .POST,
        .location = .{ .url = url },
        .extra_headers = &headers,
        .payload = body_str,
        .response_storage = .{ .dynamic = &body },
    });
    if (result.status != .ok) return error.BadStatus;
    return body.toOwnedSlice();
}
