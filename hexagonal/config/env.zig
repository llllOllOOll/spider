const std = @import("std");
const c = @cImport(@cInclude("stdlib.h"));

pub const ServerConfig = struct {
    host: []const u8,
    port: u16,
};

pub fn getEnv(key: []const u8, default: []const u8) []const u8 {
    var key_null: [256]u8 = undefined;
    @memcpy(key_null[0..key.len], key);
    key_null[key.len] = 0;
    if (c.getenv(&key_null)) |val| {
        return std.mem.sliceTo(val, 0);
    }
    return default;
}

pub fn getEnvInt(key: []const u8, default: u16) u16 {
    var key_null: [256]u8 = undefined;
    @memcpy(key_null[0..key.len], key);
    key_null[key.len] = 0;
    if (c.getenv(&key_null)) |val| {
        return std.fmt.parseInt(u16, std.mem.sliceTo(val, 0), 10) catch default;
    }
    return default;
}

pub fn getServerConfig() ServerConfig {
    return .{
        .host = getEnv("HOST", "0.0.0.0"),
        .port = getEnvInt("PORT", 8081),
    };
}
