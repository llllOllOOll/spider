const std = @import("std");
const web = @import("web.zig");

const Handler = web.Handler;
const Method = web.Method;

const Node = struct {
    children: std.StringHashMap(*Node),
    param_child: ?*Node,
    param_name: ?[]const u8,
    wildcard_child: ?*Node,
    handlers: std.EnumArray(Method, ?Handler),
    is_static_handler: bool = false,

    pub fn init(allocator: std.mem.Allocator) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .children = std.StringHashMap(*Node).init(allocator),
            .param_child = null,
            .param_name = null,
            .wildcard_child = null,
            .handlers = std.EnumArray(Method, ?Handler).initFill(null),
            .is_static_handler = false,
        };
        return node;
    }
};

pub const MatchResult = struct {
    handler: Handler,
    params: std.StringHashMapUnmanaged([]const u8),
};

pub const Group = struct {
    router: *Router,
    prefix: []const u8,

    pub fn init(router: *Router, prefix: []const u8) Group {
        return .{ .router = router, .prefix = prefix };
    }

    pub fn get(self: Group, path: []const u8, handler: Handler) !void {
        const full_path = try self.joinPrefix(path);
        try self.router.add(.get, full_path, handler);
    }

    pub fn post(self: Group, path: []const u8, handler: Handler) !void {
        const full_path = try self.joinPrefix(path);
        try self.router.add(.post, full_path, handler);
    }

    pub fn put(self: Group, path: []const u8, handler: Handler) !void {
        const full_path = try self.joinPrefix(path);
        try self.router.add(.put, full_path, handler);
    }

    pub fn delete(self: Group, path: []const u8, handler: Handler) !void {
        const full_path = try self.joinPrefix(path);
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

fn isDynamic(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, ':') != null or
        std.mem.indexOfScalar(u8, path, '*') != null;
}

fn toUppercase(in: []const u8, out: []u8) void {
    for (in, 0..) |c, i| {
        if (c >= 'a' and c <= 'z') {
            out[i] = c - 32;
        } else {
            out[i] = c;
        }
    }
}

pub const Router = struct {
    root: *Node,
    allocator: std.mem.Allocator,
    static_routes: std.StringHashMap(Handler),

    pub fn init(allocator: std.mem.Allocator) !Router {
        return .{
            .root = try Node.init(allocator),
            .allocator = allocator,
            .static_routes = std.StringHashMap(Handler).init(allocator),
        };
    }

    pub fn deinit(self: *Router) void {
        var it = self.static_routes.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.static_routes.deinit();
        self.deinitNode(self.root);
    }

    pub fn group(self: *Router, prefix: []const u8) Group {
        return Group.init(self, prefix);
    }

    fn deinitNode(self: *Router, node: *Node) void {
        var child_it = node.children.iterator();
        while (child_it.next()) |entry| {
            self.deinitNode(entry.value_ptr.*);
        }
        if (node.param_child) |n| self.deinitNode(n);
        if (node.wildcard_child) |n| self.deinitNode(n);
        node.children.deinit();
        self.allocator.destroy(node);
    }

    pub fn add(self: *Router, method: Method, path: []const u8, handler: Handler) !void {
        if (!isDynamic(path)) {
            const method_str = @tagName(method);
            // Skip leading slash in path to avoid double slashes in key
            const path_stripped = if (path.len > 0 and path[0] == '/') path[1..] else path;
            const key = try self.allocator.alloc(u8, method_str.len + 1 + path_stripped.len);
            toUppercase(method_str, key[0..method_str.len]);
            key[method_str.len] = '/';
            @memcpy(key[method_str.len + 1 ..], path_stripped);
            try self.static_routes.put(key, handler);
            std.debug.print("ROUTER: Added static route: {s}\n", .{key});
            return;
        }

        var node = self.root;
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |segment| {
            if (segment.len == 0) continue;
            if (segment[0] == ':') {
                if (node.param_child == null) {
                    node.param_child = try Node.init(self.allocator);
                    node.param_name = segment[1..];
                }
                node = node.param_child.?;
            } else if (std.mem.eql(u8, segment, "*")) {
                if (node.wildcard_child == null) {
                    node.wildcard_child = try Node.init(self.allocator);
                }
                node = node.wildcard_child.?;
            } else {
                if (!node.children.contains(segment)) {
                    const child = try Node.init(self.allocator);
                    try node.children.put(segment, child);
                }
                node = node.children.get(segment).?;
            }
        }
        node.handlers.set(method, handler);
    }

    pub fn match(self: *Router, method: Method, path: []const u8, allocator: std.mem.Allocator) !?MatchResult {
        var key_buf: [256]u8 = undefined;
        const method_str = @tagName(method);
        // Skip leading slash in path to avoid double slashes in key
        const path_stripped = if (path.len > 0 and path[0] == '/') path[1..] else path;
        const key_len = method_str.len + 1 + path_stripped.len;
        if (key_len <= key_buf.len) {
            toUppercase(method_str, key_buf[0..method_str.len]);
            key_buf[method_str.len] = '/';
            @memcpy(key_buf[method_str.len + 1 .. key_len], path_stripped);
            const key = key_buf[0..key_len];

            if (self.static_routes.get(key)) |handler| {
                return .{ .handler = handler, .params = .{} };
            }
        }

        var params: std.StringHashMapUnmanaged([]const u8) = .{};
        errdefer params.deinit(allocator);
        var node = self.root;
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |segment| {
            if (segment.len == 0) continue;
            if (node.children.get(segment)) |child| {
                node = child;
            } else if (node.param_child) |child| {
                try params.put(allocator, node.param_name.?, segment);
                node = child;
            } else if (node.wildcard_child) |child| {
                node = child;
            } else {
                return null;
            }
        }
        const handler = node.handlers.get(method);
        if (handler == null) {
            params.deinit(allocator);
            return null;
        }
        return .{ .handler = handler.?, .params = params };
    }
};
