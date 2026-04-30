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
    // try to read spider.config.zig via anonymous module
    const root = @import("root");
    if (@hasDecl(root, "spider_config")) {
        // spider_config was registered by the dev's build.zig
        return @import("spider_config").config;
    }
    return default;
}
