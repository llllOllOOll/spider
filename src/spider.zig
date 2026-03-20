const std = @import("std");
pub const web = @import("web.zig");
pub const websocket = @import("websocket.zig");
pub const ws_hub = @import("ws_hub.zig");
pub const template = @import("template.zig");
pub const pg = @import("pg.zig");
pub const env = @import("env.zig");
pub const form = @import("form.zig");
const srv = @import("server.zig");
pub const static = @import("static_handler.zig");

pub const Request = web.Request;
pub const Response = web.Response;
pub const Method = web.Method;
pub const Group = web.Group;
pub const Context = template.Context;
pub const Value = template.Value;

pub const render = web.render;
pub const renderView = web.renderView;

pub fn renderBlock(allocator: std.mem.Allocator, view: []const u8, block_name: []const u8, data: anytype) !Response {
    const html = try template.renderBlock(view, block_name, data, allocator);
    return Response.html(allocator, html);
}

var global_ws_hub: ?*ws_hub.Hub = null;

pub fn getWsHub() *ws_hub.Hub {
    return global_ws_hub.?;
}

pub fn initWsHub(allocator: std.mem.Allocator, io: std.Io) !void {
    global_ws_hub = try allocator.create(ws_hub.Hub);
    global_ws_hub.?.* = ws_hub.Hub.init(allocator, io);
}

pub fn deinitWsHub(allocator: std.mem.Allocator) void {
    if (global_ws_hub) |hub| {
        hub.deinit();
        allocator.destroy(hub);
        global_ws_hub = null;
    }
}

pub const loadEnv = env.loadEnv;

pub const Spider = struct {
    allocator: std.mem.Allocator,
    app_ptr: *web.App,
    io: std.Io,
    host: []const u8,
    port: u16,
    static_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, host: []const u8, port: u16, config: web.AppConfig) !Spider {
        const app_ptr = try web.App.init(allocator, config);
        return Spider{
            .allocator = allocator,
            .app_ptr = app_ptr,
            .io = io,
            .host = host,
            .port = port,
            .static_dir = "",
        };
    }

    pub fn deinit(self: Spider) void {
        self.app_ptr.deinit();
    }

    pub fn get(self: Spider, path: []const u8, handler: web.Handler) Spider {
        self.app_ptr.get(path, handler) catch return self;
        return self;
    }

    pub fn post(self: Spider, path: []const u8, handler: web.Handler) Spider {
        self.app_ptr.post(path, handler) catch return self;
        return self;
    }

    pub fn put(self: Spider, path: []const u8, handler: web.Handler) Spider {
        self.app_ptr.put(path, handler) catch return self;
        return self;
    }

    pub fn delete(self: Spider, path: []const u8, handler: web.Handler) Spider {
        self.app_ptr.delete(path, handler) catch return self;
        return self;
    }

    pub fn group(self: Spider, prefix: []const u8) web.Group {
        return self.app_ptr.group(prefix);
    }

    pub fn groupGet(self: Spider, prefix: []const u8, path: []const u8, handler: web.Handler) Spider {
        const full_path = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, path }) catch return self;
        self.app_ptr.get(full_path, handler) catch {};
        return self;
    }

    pub fn groupPost(self: Spider, prefix: []const u8, path: []const u8, handler: web.Handler) Spider {
        const full_path = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, path }) catch return self;
        self.app_ptr.post(full_path, handler) catch {};
        return self;
    }

    pub fn use(self: Spider, middleware: web.MiddlewareFn) Spider {
        self.app_ptr.use(middleware) catch return self;
        return self;
    }

    pub fn staticDir(self: Spider, dir: []const u8) Spider {
        var s = self;
        s.static_dir = dir;
        return s;
    }

    pub fn listen(self: Spider) !void {
        var server = try srv.Server.init(
            self.allocator,
            self.io,
            self.host,
            self.port,
            self.static_dir,
        );
        server.setApp(self.app_ptr);
        defer server.deinit();
        try server.start();
    }
};
pub const auth = @import("auth.zig");
pub const google = @import("providers/google.zig");
pub const http_client = @import("http_curlient.zig");
