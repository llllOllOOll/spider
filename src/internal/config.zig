const std = @import("std");

pub const Env = enum {
    development,
    production,
    testing,
};

pub const Config = struct {
    port: u16 = 3000,
    host: []const u8 = "127.0.0.1",
    views_dir: ?[]const u8 = "./views",
    layout: ?[]const u8 = "layout",
    static_dir: ?[]const u8 = "./public",
    env: Env = .development,
    workers: ?usize = null,
};

pub const default = Config{};

pub fn fromRoot() Config {
    // spider_config is always available: either the project's spider.config.zig
    // (registered by myapp/build.zig) or the default fallback from spider's build.zig
    return @import("spider_config").config;
}
