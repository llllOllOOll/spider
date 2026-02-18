const std = @import("std");
pub const web = @import("web.zig");
const srv = @import("server.zig");

pub const Spider = struct {
    allocator: std.mem.Allocator,
    app_ptr: *web.App,
    io: std.Io,
    port: u16,
    static_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, port: u16) !Spider {
        const app_ptr = try web.App.init(allocator);
        return Spider{
            .allocator = allocator,
            .app_ptr = app_ptr,
            .io = io,
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

    pub fn listen(self: Spider) !void {
        var server = try srv.Server.init(
            self.allocator,
            self.io,
            self.port,
            self.static_dir,
        );
        server.setApp(self.app_ptr);
        defer server.deinit();
        try server.start();
    }
};
