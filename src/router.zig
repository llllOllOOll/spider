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

fn isDynamic(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, ':') != null;
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
        self.deinitNode(self.root);
        self.static_routes.deinit();
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
            const key = try self.allocator.alloc(u8, @tagName(method).len + 1 + path.len);
            @memcpy(key[0..@tagName(method).len], @tagName(method));
            key[@tagName(method).len] = '/';
            @memcpy(key[@tagName(method).len + 1 ..], path);
            try self.static_routes.put(key, handler);
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
        const key_len = @tagName(method).len + 1 + path.len;
        if (key_len <= key_buf.len) {
            @memcpy(key_buf[0..@tagName(method).len], @tagName(method));
            key_buf[@tagName(method).len] = '/';
            @memcpy(key_buf[@tagName(method).len + 1 .. key_len], path);
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
        if (handler == null) return null;
        return .{ .handler = handler.?, .params = params };
    }
};
