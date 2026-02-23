const std = @import("std");
const spider_pg = @import("spider_pg");
const env = @import("../config/env.zig");

pub const Pool = spider_pg.Pool;

fn parseDbUrl(allocator: std.mem.Allocator, db_url: []const u8) !spider_pg.Config {
    var config = spider_pg.Config{
        .database = "spider",
        .user = "spider",
        .password = "spider",
    };

    var allocated_host = false;
    var allocated_user = false;
    var allocated_password = false;
    var allocated_database = false;
    errdefer {
        if (allocated_host) allocator.free(config.host);
        if (allocated_user) allocator.free(config.user);
        if (allocated_password) allocator.free(config.password);
        if (allocated_database) allocator.free(config.database);
    }

    if (std.mem.startsWith(u8, db_url, "postgres://")) {
        const after_prefix = db_url[11..];
        var user_end: usize = 0;
        var host_end: usize = 0;

        for (after_prefix, 0..) |ch, i| {
            if (ch == ':' and user_end == 0) {
                user_end = i;
            }
            if (ch == '@') {
                host_end = i;
                break;
            }
        }

        if (user_end > 0 and host_end > user_end) {
            const user_part = after_prefix[0..user_end];
            const pass_start = user_end + 1;
            const pass_end = host_end;
            config.user = try allocator.dupe(u8, user_part);
            allocated_user = true;
            config.password = try allocator.dupe(u8, after_prefix[pass_start..pass_end]);
            allocated_password = true;
        } else if (host_end > 0) {
            config.user = try allocator.dupe(u8, after_prefix[0..host_end]);
            allocated_user = true;
        }

        const after_at = after_prefix[host_end + 1 ..];
        var db_start: usize = 0;
        for (after_at, 0..) |ch, i| {
            if (ch == '/') {
                db_start = i + 1;
                break;
            }
        }

        if (db_start > 0) {
            config.database = try allocator.dupe(u8, after_at[db_start..]);
            allocated_database = true;
            const host_port = after_at[0 .. db_start - 1];

            for (host_port, 0..) |ch, i| {
                if (ch == ':') {
                    config.host = try allocator.dupe(u8, host_port[0..i]);
                    allocated_host = true;
                    config.port = try std.fmt.parseInt(u16, host_port[i + 1 ..], 10);
                    break;
                }
            } else {
                config.host = try allocator.dupe(u8, host_port);
                allocated_host = true;
            }
        }
    }

    return config;
}

pub fn connect(allocator: std.mem.Allocator) !Pool {
    const db_url = env.getEnv("DATABASE_URL", "postgres://spider:spider@localhost:5433/spider");
    const config = parseDbUrl(allocator, db_url) catch |err| {
        std.log.err("Failed to parse database URL: {}", .{err});
        return err;
    };
    return Pool.init(allocator, config) catch |err| {
        std.log.err("Database connection failed — is PostgreSQL running at {s}:{d}?", .{ config.host, config.port });
        allocator.free(config.host);
        allocator.free(config.user);
        allocator.free(config.password);
        allocator.free(config.database);
        return err;
    };
}
