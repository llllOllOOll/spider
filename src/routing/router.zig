//! The router: a map of static paths and a trie of dynamic ones, each route
//! with its own middlewares and declarations (`RouteMeta`). Apps do not
//! use `Router` directly; they register routes on the server or on a
//! `spider.Group`.

const std = @import("std");
const Ctx = @import("../core/context.zig").Ctx;
const Response = @import("../core/context.zig").Response;
const MiddlewareFn = @import("../core/context.zig").MiddlewareFn;

/// The plain handler type: `fn (*spider.Ctx) !spider.Response`.
pub const Handler = *const fn (*Ctx) anyerror!Response;

// internal: a registered endpoint: the handler plus the middlewares that belong to
// that exact route (e.g. RBAC from `.{ .roles = ... }`). Stored in the
// router itself so a match on `/items/:id` carries its own middlewares:
// looking them up afterwards by comparing the request path against the
// registered pattern can never match a dynamic route.
pub const Route = struct {
    handler: Handler,
    middlewares: []const MiddlewareFn = &.{},
    meta: RouteMeta = .{},
    /// The names of the route's `:params`, in path order. Set by
    /// Router.addRoute from the path (whatever is passed in is replaced)
    /// and owned by the router: two routes may name the same position
    /// differently (`GET /posts/:author`, `POST /posts/:id`).
    param_names: []const []const u8 = &.{},
};

/// What a route declares about itself, from its config
/// (`.{ .roles, .org_roles, .public, .policy, .quiet_log, .allow_http }`, see
/// routing/route_config.zig). Available to middlewares as `c.route()`.
pub const RouteMeta = struct {
    /// No login needed: auth middlewares (jwks/keycloak/clerk, auth) let
    /// the request through.
    public: bool = false,
    /// A successful request isn't logged (heartbeats, polling); 4xx/5xx
    /// still are.
    quiet_log: bool = false,
    /// Any logged-in user (`.authenticated = true`): 401 without an identity.
    authenticated: bool = false,
    /// Served over plain HTTP even when the app forces HTTPS
    /// (spider.forceHttps) — for clients that can't do TLS.
    allow_http: bool = false,
    /// Informational copy of the RBAC config (the checks themselves are the
    /// route's middlewares): shown by the route listing.
    roles: []const []const u8 = &.{},
    org_roles: []const []const u8 = &.{},
    /// The name of the route's `.policy` (spider.policy), if any.
    policy: ?[]const u8 = null,

    /// The route says who may call it: `.public`, `.authenticated`,
    /// `.roles` / `.org_roles`, or `.policy`.
    pub fn declaresAccess(m: RouteMeta) bool {
        return m.public or m.authenticated or m.roles.len > 0 or m.org_roles.len > 0 or m.policy != null;
    }

    /// The access column of the route listing: "public", "roles:a,b",
    /// "org:a,b", "org:a roles:b", "authenticated", or "-" (nothing
    /// declared), followed by " policy:name" when the route has one
    /// ("policy:name" alone for a route with only a policy).
    pub fn writeAccess(m: RouteMeta, w: *std.Io.Writer) !void {
        if (!m.declaresAccess()) return w.writeAll("-");
        const has_roles = m.roles.len > 0 or m.org_roles.len > 0;
        if (m.public) {
            try w.writeAll("public");
        } else if (has_roles) {
            if (m.org_roles.len > 0) try writeList(w, "org:", m.org_roles);
            if (m.roles.len > 0) try writeList(w, if (m.org_roles.len > 0) " roles:" else "roles:", m.roles);
        } else if (m.authenticated or m.policy == null) {
            try w.writeAll("authenticated");
        }
        if (m.policy) |p| {
            if (m.public or has_roles or m.authenticated) try w.writeAll(" ");
            try w.print("policy:{s}", .{p});
        }
    }

    fn writeList(w: *std.Io.Writer, label: []const u8, items: []const []const u8) !void {
        try w.writeAll(label);
        for (items, 0..) |r, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll(r);
        }
    }
};

// internal: one registered route, as listed by Router.entries().
pub const Entry = struct {
    method: std.http.Method,
    /// Always starts with '/'.
    path: []const u8,
    route: Route,
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

// internal: what Router.match gives the server.
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

// internal: the server and each Group own one.
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
        for (node.handlers.values) |maybe| {
            if (maybe) |route| self.freeParamNames(route);
        }
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

        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |name| self.allocator.free(name);
            names.deinit(self.allocator);
        }

        var node = self.root;
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |segment| {
            if (segment.len == 0) continue;
            if (segment[0] == ':') {
                if (node.param_child == null) {
                    node.param_child = try Node.init(self.allocator);
                    node.param_name = try self.allocator.dupe(u8, segment[1..]);
                }
                const name = try self.allocator.dupe(u8, segment[1..]);
                errdefer self.allocator.free(name);
                try names.append(self.allocator, name);
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
        if (node.handlers.get(method)) |old| {
            self.warnDuplicate(method, path);
            self.freeParamNames(old);
        }
        var stored = route;
        stored.param_names = try names.toOwnedSlice(self.allocator);
        node.handlers.set(method, stored);
    }

    fn freeParamNames(self: *Router, route: Route) void {
        for (route.param_names) |name| self.allocator.free(name);
        self.allocator.free(route.param_names);
    }

    fn warnDuplicate(self: *Router, method: std.http.Method, path: []const u8) void {
        self.duplicates += 1;
        std.log.warn("route {s} {s} registered twice; the later registration wins", .{ @tagName(method), path });
    }

    /// Every route, sorted by path then method. Free with freeEntries().
    pub fn entries(self: *Router, allocator: std.mem.Allocator) ![]Entry {
        const Collect = struct {
            list: *std.ArrayListUnmanaged(Entry),
            alloc: std.mem.Allocator,
            failed: *bool,
            fn cb(c: @This(), method: std.http.Method, path: []const u8, route: Route) void {
                const p = (if (path.len > 0 and path[0] == '/')
                    c.alloc.dupe(u8, path)
                else
                    std.fmt.allocPrint(c.alloc, "/{s}", .{path})) catch {
                    c.failed.* = true;
                    return;
                };
                c.list.append(c.alloc, .{ .method = method, .path = p, .route = route }) catch {
                    c.alloc.free(p);
                    c.failed.* = true;
                };
            }
        };
        var list: std.ArrayListUnmanaged(Entry) = .empty;
        var failed = false;
        self.forEach(allocator, Collect{ .list = &list, .alloc = allocator, .failed = &failed }, Collect.cb);
        if (failed) {
            for (list.items) |e| allocator.free(e.path);
            list.deinit(allocator);
            return error.OutOfMemory;
        }
        std.mem.sort(Entry, list.items, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                const o = std.mem.order(u8, a.path, b.path);
                if (o != .eq) return o == .lt;
                return @backingInt(a.method) < @backingInt(b.method);
            }
        }.lt);
        return list.toOwnedSlice(allocator);
    }

    pub fn freeEntries(allocator: std.mem.Allocator, list: []Entry) void {
        for (list) |e| allocator.free(e.path);
        allocator.free(list);
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

    /// `trie_path` with each `:param` renamed to the route's own name for
    /// it (the trie keeps the first name registered at a position). Null
    /// when out of memory: the caller falls back to the trie's names.
    fn ownPath(allocator: std.mem.Allocator, trie_path: []const u8, names: []const []const u8) ?[]u8 {
        var out: std.ArrayList(u8) = .empty;
        var next: usize = 0;
        var it = std.mem.splitScalar(u8, trie_path, '/');
        while (it.next()) |segment| {
            if (segment.len == 0) continue;
            out.append(allocator, '/') catch return null;
            if (segment[0] == ':' and next < names.len) {
                out.append(allocator, ':') catch return null;
                out.appendSlice(allocator, names[next]) catch return null;
                next += 1;
            } else {
                out.appendSlice(allocator, segment) catch return null;
            }
        }
        return out.toOwnedSlice(allocator) catch null;
    }

    fn forEachNode(node: *Node, path_buf: *std.ArrayList(u8), allocator: std.mem.Allocator, context: anytype, comptime callback: fn (@TypeOf(context), std.http.Method, []const u8, Route) void) void {
        inline for (std.meta.tags(std.http.Method)) |method| {
            if (node.handlers.get(method)) |r| {
                if (ownPath(allocator, path_buf.items, r.param_names)) |own| {
                    defer allocator.free(own);
                    callback(context, method, own, r);
                } else {
                    callback(context, method, path_buf.items, r);
                }
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
        // The values of the :params, in path order; they get their names
        // from the matched route once it is known.
        var values: std.ArrayList([]const u8) = .empty;
        defer values.deinit(allocator);
        var node = self.root;
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |segment| {
            if (segment.len == 0) continue;
            if (node.children.get(segment)) |child| {
                node = child;
            } else if (node.param_child) |child| {
                const value = try allocator.dupe(u8, segment);
                errdefer allocator.free(value);
                try values.append(allocator, value);
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
        for (values.items, 0..) |value, i| {
            if (i >= route.param_names.len) break;
            const key = try allocator.dupe(u8, route.param_names[i]);
            errdefer allocator.free(key);
            try params.put(allocator, key, value);
        }
        return .{ .handler = route.handler, .params = params, .middlewares = route.middlewares, .meta = route.meta };
    }
};
