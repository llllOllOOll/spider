const std = @import("std");
const Router = @import("router.zig").Router;
const Handler = @import("../web.zig").Handler;

pub const Group = struct {
    router: *Router,
    prefix: []const u8,

    pub fn init(router: *Router, prefix: []const u8) Group {
        return .{ .router = router, .prefix = prefix };
    }

    pub fn get(self: Group, path: []const u8, handler: Handler) !void {
        const full_path = try self.joinPrefix(path);
        defer if (full_path.ptr != path.ptr) self.router.allocator.free(full_path);
        try self.router.add(.get, full_path, handler);
    }

    pub fn post(self: Group, path: []const u8, handler: Handler) !void {
        const full_path = try self.joinPrefix(path);
        defer if (full_path.ptr != path.ptr) self.router.allocator.free(full_path);
        try self.router.add(.post, full_path, handler);
    }

    pub fn put(self: Group, path: []const u8, handler: Handler) !void {
        const full_path = try self.joinPrefix(path);
        defer if (full_path.ptr != path.ptr) self.router.allocator.free(full_path);
        try self.router.add(.put, full_path, handler);
    }

    pub fn delete(self: Group, path: []const u8, handler: Handler) !void {
        const full_path = try self.joinPrefix(path);
        defer if (full_path.ptr != path.ptr) self.router.allocator.free(full_path);
        try self.router.add(.delete, full_path, handler);
    }

    fn joinPrefix(self: Group, path: []const u8) ![]const u8 {
        if (self.prefix.len == 0) return path;
        if (path.len == 0) return self.prefix;

        const needs_slash = self.prefix[self.prefix.len - 1] != '/' and path[0] != '/';
        if (needs_slash) {
            return std.fmt.allocPrint(self.router.allocator, "{s}/{s}", .{ self.prefix, path });
        }
        return std.fmt.allocPrint(self.router.allocator, "{s}{s}", .{ self.prefix, path });
    }
};
