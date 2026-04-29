//! Speed - A fast, ergonomic web framework for Zig
//! Focused on great Developer Experience (DX) for developers coming from Go, Django, TypeScript

const std = @import("std");

pub const Ctx = @import("core/context.zig").Ctx;
pub const NextFn = @import("core/context.zig").NextFn;
pub const MiddlewareFn = @import("core/context.zig").MiddlewareFn;
pub const ErrorHandler = @import("core/context.zig").ErrorHandler;
pub const Database = @import("core/database.zig").Database;
pub const DatabaseCtx = @import("core/context.zig").DatabaseCtx;
pub const PgDriver = @import("drivers/pg/pg.zig").PgDriver;
pub const sqlite = @import("drivers/sqlite/sqlite.zig");
pub const SqliteDriver = sqlite.SqliteDriver;
pub const app = @import("core/app.zig").app;
pub const server = @import("core/app.zig").server;
pub const Server = @import("core/app.zig").Server;
pub const StaticConfig = @import("core/app.zig").StaticConfig;
pub const Router = @import("routing/router.zig").Router;
pub const Group = @import("routing/group.zig").Group;
pub const websocket = @import("ws/websocket.zig");
pub const Hub = @import("ws/hub.zig").Hub;
pub const pg = @import("drivers/pg/pg.zig");
pub const mysql = @import("drivers/mysql/mysql.zig");
pub const pg_pool = @import("drivers/pg/pool.zig");
pub const auth = @import("modules/auth/auth.zig");
pub const static = @import("modules/static.zig");
pub const dashboard = @import("modules/dashboard.zig");
pub const Request = @import("web.zig").Request;
pub const Response = @import("core/context.zig").Response;
pub const Method = @import("web.zig").Method;
pub const metrics = @import("internal/metrics.zig");
pub const env = @import("internal/env.zig");
pub const template = @import("render/template.zig");
pub const zmd = @import("render/zmd/zmd.zig");
pub const form = @import("binding/form.zig");
pub const form_parser = @import("binding/form_parser.zig");

var global_ws_hub: ?*Hub = null;

pub fn getWsHub() *Hub {
    return global_ws_hub.?;
}

pub fn initWsHub(allocator: std.mem.Allocator, io: std.Io) !void {
    global_ws_hub = try allocator.create(Hub);
    global_ws_hub.?.* = Hub.init(allocator, io);
}

pub fn deinitWsHub(allocator: std.mem.Allocator) void {
    if (global_ws_hub) |hub| {
        hub.deinit();
        allocator.destroy(hub);
        global_ws_hub = null;
    }
}
