const std = @import("std");
const Ctx = @import("../core/context.zig").Ctx;
const Response = @import("../core/context.zig").Response;
const MiddlewareFn = @import("../core/context.zig").MiddlewareFn;

pub const Handler = *const fn (*Ctx) anyerror!Response;

/// A registered endpoint: the handler plus the middlewares that belong to
/// that exact route (e.g. RBAC from `.{ .roles = ... }`). Stored in the
/// router itself so a match on `/items/:id` carries its own middlewares —
/// looking them up afterwards by comparing the request path against the
/// registered pattern can never match a dynamic route.
pub const Route = struct {
    handler: Handler,
    middlewares: []const MiddlewareFn = &.{},
    meta: RouteMeta = .{},
};

/// What a route declares about itself, from its config
/// (`.{ .roles, .org_roles, .public, .quiet_log, .allow_http }`, see
/// routing/route_config.zig). Available to middlewares as `c.route()`.
pub const RouteMeta = struct {
    /// No login needed: auth middlewares (jwks/keycloak/clerk, auth) let
    /// the request through.
    public: bool = false,
    /// A successful request isn't logged (heartbeats, polling); 4xx/5xx
    /// still are.
    quiet_log: bool = false,
    /// Served over plain HTTP even when the app forces HTTPS
    /// (spider.forceHttps) — for clients that can't do TLS.
    allow_http: bool = false,
    /// Informational copy of the RBAC config (the checks themselves are the
    /// route's middlewares): shown by the route listing.
    roles: []const []const u8 = &.{},
    org_roles: []const []const u8 = &.{},
};

const Node = struct {
    children: std.StringHashMap(*Node),
    param_child: ?*Node,
    param_name: ?[]const u8,
    wildcard_child: ?*Node,
    handlers: std.EnumArray(std.http.Method, ?Route),
    is_static_handler: bool = false,

    pub fn init(allocator: std.mem.Allocator) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .children = std.StringHashMap(*Node).init(allocator),
            .param_child = null,
            .param_name = null,
            .wildcard_child = null,
            .handlers = std.EnumArray(std.http.Method, ?Route).initFill(null),
            .is_static_handler = false,
        };
        return node;
    }
};

pub const MatchResult = struct {
    handler: Handler,
    params: std.StringHashMapUnmanaged([]const u8),
    /// Middlewares registered for the matched route only (see `Route`).
    middlewares: []const MiddlewareFn = &.{},
    meta: RouteMeta = .{},
};

fn isDynamic(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, ':') != null or
        std.mem.indexOfScalar(u8, path, '*') != null;
}

fn toUppercase(in: []const u8, out: []u8) void {
    for (in, 0..) |c, i| {
        out[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
    }
}

pub const Router = struct {
    root: *Node,
    allocator: std.mem.Allocator,
    /// Registrations of a method+path that already had a route (the later
    /// one wins, as it always did; now it's logged).
    duplicates: usize = 0,
    static_routes: std.StringHashMap(Route),

    pub fn init(allocator: std.mem.Allocator) !Router {
        return .{
            .root = try Node.init(allocator),
            .allocator = allocator,
            .static_routes = std.StringHashMap(Route).init(allocator),
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

    fn deinitNode(self: *Router, node: *Node) void {
        var child_it = node.children.iterator();
        while (child_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.deinitNode(entry.value_ptr.*);
        }
        if (node.param_child) |n| {
            if (node.param_name) |name| self.allocator.free(name);
            self.deinitNode(n);
        }
        if (node.wildcard_child) |n| self.deinitNode(n);
        node.children.deinit();
        self.allocator.destroy(node);
    }

    pub fn add(self: *Router, method: std.http.Method, path: []const u8, handler: Handler) !void {
        return self.addRoute(method, path, .{ .handler = handler });
    }

    pub fn addRoute(self: *Router, method: std.http.Method, path: []const u8, route: Route) !void {
        if (!isDynamic(path)) {
            const method_str = @tagName(method);
            const path_stripped = if (path.len > 0 and path[0] == '/') path[1..] else path;
            const key = try self.allocator.alloc(u8, method_str.len + 1 + path_stripped.len);
            toUppercase(method_str, key[0..method_str.len]);
            key[method_str.len] = '/';
            @memcpy(key[method_str.len + 1 ..], path_stripped);
            const gop = try self.static_routes.getOrPut(key);
            if (gop.found_existing) {
                self.allocator.free(key);
                self.warnDuplicate(method, path);
            }
            gop.value_ptr.* = route;
            return;
        }

        var node = self.root;
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |segment| {
            if (segment.len == 0) continue;
            if (segment[0] == ':') {
                if (node.param_child == null) {
                    node.param_child = try Node.init(self.allocator);
                    node.param_name = try self.allocator.dupe(u8, segment[1..]);
                } else if (!std.mem.eql(u8, node.param_name orelse "", segment[1..])) {
                    std.debug.print("ROUTER: Warning: parameter conflict at segment '{s}'\n", .{segment});
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
                    const owned_seg = try self.allocator.dupe(u8, segment);
                    try node.children.put(owned_seg, child);
                }
                node = node.children.get(segment).?;
            }
        }
        if (node.handlers.get(method) != null) self.warnDuplicate(method, path);
        node.handlers.set(method, route);
    }

    fn warnDuplicate(self: *Router, method: std.http.Method, path: []const u8) void {
        self.duplicates += 1;
        std.log.warn("route {s} {s} registered twice; the later registration wins", .{ @tagName(method), path });
    }

    pub fn forEach(self: *Router, allocator: std.mem.Allocator, context: anytype, comptime callback: fn (@TypeOf(context), std.http.Method, []const u8, Route) void) void {
        var static_it = self.static_routes.iterator();
        while (static_it.next()) |entry| {
            const key = entry.key_ptr.*;
            const route = entry.value_ptr.*;
            const slash = std.mem.indexOfScalar(u8, key, '/') orelse continue;
            const method = std.meta.stringToEnum(std.http.Method, key[0..slash]) orelse continue;
            callback(context, method, key[slash + 1 ..], route);
        }

        var path_buf: std.ArrayList(u8) = .empty;
        defer path_buf.deinit(allocator);
        forEachNode(self.root, &path_buf, allocator, context, callback);
    }

    fn forEachNode(node: *Node, path_buf: *std.ArrayList(u8), allocator: std.mem.Allocator, context: anytype, comptime callback: fn (@TypeOf(context), std.http.Method, []const u8, Route) void) void {
        inline for (std.meta.tags(std.http.Method)) |method| {
            if (node.handlers.get(method)) |r| {
                callback(context, method, path_buf.items, r);
            }
        }

        var child_it = node.children.iterator();
        while (child_it.next()) |entry| {
            const seg = entry.key_ptr.*;
            const start = path_buf.items.len;
            path_buf.append(allocator, '/') catch return;
            path_buf.appendSlice(allocator, seg) catch {
                path_buf.items.len = start;
                return;
            };
            forEachNode(entry.value_ptr.*, path_buf, allocator, context, callback);
            path_buf.items.len = start;
        }

        if (node.param_child) |child| {
            const start = path_buf.items.len;
            path_buf.append(allocator, '/') catch return;
            path_buf.append(allocator, ':') catch return;
            path_buf.appendSlice(allocator, node.param_name.?) catch {
                path_buf.items.len = start;
                return;
            };
            forEachNode(child, path_buf, allocator, context, callback);
            path_buf.items.len = start;
        }

        if (node.wildcard_child) |child| {
            const start = path_buf.items.len;
            path_buf.append(allocator, '/') catch return;
            path_buf.append(allocator, '*') catch {
                path_buf.items.len = start;
                return;
            };
            forEachNode(child, path_buf, allocator, context, callback);
            path_buf.items.len = start;
        }
    }

    pub fn match(self: *Router, method: std.http.Method, path: []const u8, allocator: std.mem.Allocator) !?MatchResult {
        var key_buf: [256]u8 = undefined;
        const method_str = @tagName(method);
        const path_stripped = if (path.len > 0 and path[0] == '/') path[1..] else path;
        const key_len = method_str.len + 1 + path_stripped.len;
        if (key_len <= key_buf.len) {
            toUppercase(method_str, key_buf[0..method_str.len]);
            key_buf[method_str.len] = '/';
            @memcpy(key_buf[method_str.len + 1 .. key_len], path_stripped);
            const key = key_buf[0..key_len];
            if (self.static_routes.get(key)) |route| {
                return .{ .handler = route.handler, .params = .{}, .middlewares = route.middlewares, .meta = route.meta };
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
                const key = try allocator.dupe(u8, node.param_name.?);
                errdefer allocator.free(key);
                const value = try allocator.dupe(u8, segment);
                errdefer allocator.free(value);
                try params.put(allocator, key, value);
                node = child;
            } else if (node.wildcard_child) |child| {
                const key = try allocator.dupe(u8, "*");
                errdefer allocator.free(key);
                const value = try allocator.dupe(u8, segment);
                errdefer allocator.free(value);
                try params.put(allocator, key, value);
                node = child;
            } else {
                return null;
            }
        }
        const route = node.handlers.get(method) orelse {
            params.deinit(allocator);
            return null;
        };
        return .{ .handler = route.handler, .params = params, .middlewares = route.middlewares, .meta = route.meta };
    }
};
