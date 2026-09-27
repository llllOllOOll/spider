const std = @import("std");
const Router = @import("router.zig").Router;
const Handler = @import("router.zig").Handler;
const RouteMeta = @import("router.zig").RouteMeta;
const route_config = @import("route_config.zig");
const handler_mod = @import("../core/handler.zig");
const MiddlewareFn = @import("../core/context.zig").MiddlewareFn;
const sse_mod = @import("../ws/sse.zig");
const Sse = sse_mod.Sse;

const PathMiddlewareEntry = struct {
    path: []const u8,
    middleware: MiddlewareFn,
};

/// A set of routes under one prefix, built by a feature and mounted on the
/// server (`server.mount(g)` or `server.mountFeatures(features)`).
///
///     var g = spider.Group.init("/tickets");
///     _ = g
///         .defaults(.{ .org_roles = ticket_roles })   // before the routes
///         .get("", controller.index, .{})              // inherits the defaults
///         .post("/:id/approve", controller.approve, .{ .org_roles = admin_roles }) // replaces them
///         .get("/public-feed", controller.feed, .{ .public = true });              // opts out
///
/// Routes take the same config as server routes (routing/route_config.zig)
/// and plain or extractor handlers (spider.Path / spider.Form).
pub const Group = struct {
    router: *Router,
    prefix: []const u8,
    path_middlewares: [32]PathMiddlewareEntry = undefined,
    path_middleware_count: usize = 0,
    has_sse: bool = false,
    /// From defaults(): RBAC middlewares and flags for routes that don't
    /// declare their own access rules.
    default_middlewares: []const MiddlewareFn = &.{},
    default_meta: RouteMeta = .{},
    /// From use(): run on every route of the group, after its RBAC checks.
    use_middlewares: [16]MiddlewareFn = undefined,
    use_count: usize = 0,
    route_count: usize = 0,

    pub fn init(prefix: []const u8) Group {
        const r = std.heap.page_allocator.create(Router) catch @panic("OOM");
        r.* = Router.init(std.heap.page_allocator) catch @panic("OOM");
        return .{
            .router = r,
            .prefix = prefix,
            .path_middleware_count = 0,
        };
    }

    /// Access rules and flags every route of the group inherits unless the
    /// route declares its own `.roles` / `.org_roles` / `.public` /
    /// `.authenticated` / `.policy`
    /// (`.quiet_log` / `.allow_http` are overridden one by one). Must come
    /// before the group's routes.
    pub fn defaults(self: *Group, comptime config: anytype) *Group {
        comptime route_config.validate(config);
        if (self.route_count > 0) std.debug.panic("Group \"{s}\": defaults() must come before the group's routes", .{self.prefix});
        self.default_middlewares = comptime route_config.middlewares(config);
        self.default_meta = comptime route_config.metaOf(config);
        return self;
    }

    /// Middleware for every route of this group (applied when the group is
    /// mounted, so the order relative to the routes doesn't matter). Runs
    /// after the route's RBAC checks. Unlike useAt(), it's tied to the
    /// routes, not to a path prefix.
    pub fn use(self: *Group, m: MiddlewareFn) *Group {
        if (self.use_count >= self.use_middlewares.len) std.debug.panic("Group \"{s}\": more than {d} use() middlewares", .{ self.prefix, self.use_middlewares.len });
        self.use_middlewares[self.use_count] = m;
        self.use_count += 1;
        return self;
    }

    pub fn get(self: *Group, path: []const u8, handler: anytype, comptime config: anytype) *Group {
        return self.route(.GET, path, toHandler(handler), config);
    }

    pub fn post(self: *Group, path: []const u8, handler: anytype, comptime config: anytype) *Group {
        return self.route(.POST, path, toHandler(handler), config);
    }

    pub fn put(self: *Group, path: []const u8, handler: anytype, comptime config: anytype) *Group {
        return self.route(.PUT, path, toHandler(handler), config);
    }

    pub fn delete(self: *Group, path: []const u8, handler: anytype, comptime config: anytype) *Group {
        return self.route(.DELETE, path, toHandler(handler), config);
    }

    pub fn patch(self: *Group, path: []const u8, handler: anytype, comptime config: anytype) *Group {
        return self.route(.PATCH, path, toHandler(handler), config);
    }

    pub fn head(self: *Group, path: []const u8, handler: anytype, comptime config: anytype) *Group {
        return self.route(.HEAD, path, toHandler(handler), config);
    }

    /// A ready `Handler` value (possibly only known at runtime, e.g.
    /// keycloak.loginHandler()) is used as is; a function goes through
    /// extractor detection at compile time.
    fn toHandler(handler: anytype) Handler {
        if (@TypeOf(handler) == Handler) return handler;
        return comptime handler_mod.forGroup(handler);
    }

    fn route(self: *Group, method: std.http.Method, path: []const u8, h: Handler, comptime config: anytype) *Group {
        comptime route_config.validate(config);
        const own = comptime route_config.metaOf(config);
        const T = @TypeOf(config);
        var meta = self.default_meta;
        var mws = self.default_middlewares;
        if (comptime route_config.declaresAccess(config)) {
            mws = comptime route_config.middlewares(config);
            meta.public = own.public;
            meta.authenticated = own.authenticated;
            meta.roles = own.roles;
            meta.org_roles = own.org_roles;
            meta.policy = own.policy;
        }
        if (comptime @hasField(T, "quiet_log")) meta.quiet_log = own.quiet_log;
        if (comptime @hasField(T, "allow_http")) meta.allow_http = own.allow_http;

        const full = self.join(path) catch unreachable;
        self.router.addRoute(method, full, .{ .handler = h, .middlewares = mws, .meta = meta }) catch unreachable;
        self.freeJoined(path, full);
        self.route_count += 1;
        return self;
    }

    // No RBAC config param — Server.sse() doesn't take one either, so this
    // isn't a new inconsistency. buildHandler lives in ws/sse.zig (not
    // app.zig) specifically so this can call it without a circular import.
    pub fn sse(self: *Group, path: []const u8, comptime handler: fn (*Sse) anyerror!void) *Group {
        const full = self.join(path) catch unreachable;
        self.router.add(.GET, full, sse_mod.buildHandler(handler)) catch unreachable;
        self.freeJoined(path, full);
        self.has_sse = true;
        return self;
    }

    /// sse() with a route config, like get(): the group's defaults() apply
    /// unless the config declares its own access. (sse() takes neither.)
    pub fn sseWith(self: *Group, path: []const u8, comptime handler: fn (*Sse) anyerror!void, comptime config: anytype) *Group {
        self.has_sse = true;
        return self.route(.GET, path, sse_mod.buildHandler(handler), config);
    }

    pub fn useAt(self: *Group, path_suffix: []const u8, m: MiddlewareFn) *Group {
        const full = self.join(path_suffix) catch return self;
        if (self.path_middleware_count >= self.path_middlewares.len) {
            std.debug.panic(
                "Group.useAt: path middleware capacity exceeded (max {d}) registering \"{s}\" on group prefix \"{s}\"",
                .{ self.path_middlewares.len, full, self.prefix },
            );
        }
        self.path_middlewares[self.path_middleware_count] = .{ .path = full, .middleware = m };
        self.path_middleware_count += 1;
        return self;
    }

    // join() only allocates when it returns a freshly built "prefix + path" buffer;
    // its two early-return paths hand back a caller-owned slice (path or self.prefix)
    // that must never be freed.
    fn freeJoined(self: Group, path: []const u8, full: []const u8) void {
        if (full.ptr == path.ptr) return;
        if (full.ptr == self.prefix.ptr) return;
        self.router.allocator.free(full);
    }

    fn join(self: Group, path: []const u8) ![]const u8 {
        if (self.prefix.len == 0) return path;
        if (path.len == 0) return self.prefix;
        const prefix_has_slash = self.prefix[self.prefix.len - 1] == '/';
        const path_has_slash = path[0] == '/';
        if (prefix_has_slash and path_has_slash) {
            return std.fmt.allocPrint(self.router.allocator, "{s}{s}", .{ self.prefix, path[1..] });
        }
        if (!prefix_has_slash and !path_has_slash) {
            return std.fmt.allocPrint(self.router.allocator, "{s}/{s}", .{ self.prefix, path });
        }
        return std.fmt.allocPrint(self.router.allocator, "{s}{s}", .{ self.prefix, path });
    }
};
