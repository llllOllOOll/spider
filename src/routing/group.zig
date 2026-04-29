const std = @import("std");
const Router = @import("router.zig").Router;
const Handler = @import("router.zig").Handler;

pub const Group = struct {
    router: *Router,
    prefix: []const u8,

    pub fn init(router: *Router, prefix: []const u8) Group {
        return .{ .router = router, .prefix = prefix };
    }

    pub fn get(self: Group, path: []const u8, handler: Handler) !void {
        const full = try self.join(path);
        defer if (full.ptr != path.ptr) self.router.allocator.free(full);
        try self.router.add(.GET, full, handler);
    }

    pub fn post(self: Group, path: []const u8, handler: Handler) !void {
        const full = try self.join(path);
        defer if (full.ptr != path.ptr) self.router.allocator.free(full);
        try self.router.add(.POST, full, handler);
    }

    pub fn put(self: Group, path: []const u8, handler: Handler) !void {
        const full = try self.join(path);
        defer if (full.ptr != path.ptr) self.router.allocator.free(full);
        try self.router.add(.PUT, full, handler);
    }

    pub fn delete(self: Group, path: []const u8, handler: Handler) !void {
        const full = try self.join(path);
        defer if (full.ptr != path.ptr) self.router.allocator.free(full);
        try self.router.add(.DELETE, full, handler);
    }

    fn join(self: Group, path: []const u8) ![]const u8 {
        if (self.prefix.len == 0) return path;
        if (path.len == 0) return self.prefix;
        const needs_slash = self.prefix[self.prefix.len - 1] != '/' and path[0] != '/';
        if (needs_slash) {
            return std.fmt.allocPrint(self.router.allocator, "{s}/{s}", .{ self.prefix, path });
        }
        return std.fmt.allocPrint(self.router.allocator, "{s}{s}", .{ self.prefix, path });
    }
};
