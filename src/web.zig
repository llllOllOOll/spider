const std = @import("std");
const router_mod = @import("router.zig");
const template = @import("template.zig");
const form = @import("form.zig");
const Route = router_mod;

pub const Group = Route.Group;
pub const Method = enum {
    get,
    post,
    put,
    patch,
    delete,
    options,
    head,
};

pub const Status = enum(u16) {
    ok = 200,
    created = 201,
    accepted = 202,
    no_content = 204,
    found = 302,
    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    conflict = 409,
    unprocessable_entity = 422,
    too_many_requests = 429,
    internal_server_error = 500,
    not_implemented = 501,
    bad_gateway = 502,
    service_unavailable = 503,
};

pub const Headers = struct {
    map: std.StringHashMapUnmanaged([]const u8),

    pub fn init() Headers {
        return .{ .map = .{} };
    }

    pub fn get(self: *const Headers, name: []const u8) ?[]const u8 {
        return self.map.get(name);
    }

    pub fn set(self: *Headers, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        const name_dup = try allocator.dupe(u8, name);
        errdefer allocator.free(name_dup);
        const value_dup = try allocator.dupe(u8, value);
        errdefer allocator.free(value_dup);
        try self.map.put(allocator, name_dup, value_dup);
    }

    pub fn has(self: *const Headers, name: []const u8) bool {
        return self.map.contains(name);
    }
};

pub const Request = struct {
    method: Method,
    path: []const u8,
    query: ?[]const u8,
    headers: Headers,
    body: ?[]const u8,
    params: std.StringHashMapUnmanaged([]const u8),

    _app: ?*App = null,
    _handler: ?Handler = null,
    _middleware_index: usize = 0,
    io: std.Io = undefined,

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        var params_iter = self.params.iterator();
        while (params_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.params.deinit(allocator);
        self.headers.map.deinit(allocator);
    }

    pub fn parse(allocator: std.mem.Allocator, raw: []const u8) !Request {
        var req = Request{
            .method = .get,
            .path = "",
            .query = null,
            .headers = Headers.init(),
            .body = null,
            .params = .{},
        };

        var lines = std.mem.splitSequence(u8, raw, "\r\n");

        const request_line = lines.next() orelse return error.InvalidRequest;
        var parts = std.mem.splitScalar(u8, request_line, ' ');
        const method_str = parts.next() orelse return error.InvalidRequest;
        const url = parts.next() orelse return error.InvalidRequest;

        req.method = parseMethod(method_str);

        if (std.mem.indexOfScalar(u8, url, '?')) |q| {
            req.path = url[0..q];
            req.query = url[q + 1 ..];
        } else {
            req.path = url;
        }

        while (lines.next()) |line| {
            if (line.len == 0) break;
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                var name_buf: [128]u8 = undefined;
                const name = std.ascii.lowerString(&name_buf, std.mem.trim(u8, line[0..colon], " "));
                const value = std.mem.trim(u8, line[colon + 1 ..], " ");
                try req.headers.set(allocator, try allocator.dupe(u8, name), value);
            }
        }

        if (std.mem.indexOf(u8, raw, "\r\n\r\n")) |b| {
            const body = raw[b + 4 ..];
            if (body.len > 0) req.body = body;
        }

        return req;
    }

    fn parseMethod(s: []const u8) Method {
        var buf: [16]u8 = undefined;
        const lower = std.ascii.lowerString(&buf, s);
        return std.meta.stringToEnum(Method, lower) orelse .get;
    }

    pub fn queryParam(self: *const Request, name: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        const q = self.query orelse return null;
        var iter = std.mem.splitScalar(u8, q, '&');
        while (iter.next()) |pair| {
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                if (std.mem.eql(u8, pair[0..eq], name)) {
                    return try urlDecode(pair[eq + 1 ..], allocator);
                }
            }
        }
        return null;
    }

    pub fn formParam(self: *const Request, name: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        const body = self.body orelse return null;
        var iter = std.mem.splitScalar(u8, body, '&');
        while (iter.next()) |pair| {
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                const key = pair[0..eq];
                const value = pair[eq + 1 ..];
                if (std.mem.eql(u8, key, name)) {
                    return try urlDecode(value, allocator);
                }
            }
        }
        return null;
    }

    fn urlDecode(s: []const u8, allocator: std.mem.Allocator) ![]u8 {
        var result = try allocator.alloc(u8, s.len);
        var j: usize = 0;

        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] == '%' and i + 2 < s.len) {
                const hex = s[i + 1 .. i + 3];
                const decoded = try std.fmt.parseInt(u8, hex, 16);
                result[j] = decoded;
                i += 2;
            } else if (s[i] == '+') {
                result[j] = ' ';
            } else {
                result[j] = s[i];
            }
            j += 1;
        }
        return result[0..j];
    }

    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    pub fn bindJson(self: *const Request, allocator: std.mem.Allocator, comptime T: type) !T {
        const body = self.body orelse return error.BodyEmpty;
        const parsed = try std.json.parseFromSlice(T, allocator, body, .{
            .ignore_unknown_fields = true,
        });
        return parsed.value;
    }

    pub fn param(self: *const Request, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    pub fn form(self: *Request, allocator: std.mem.Allocator) !@import("form.zig").FormData {
        return @import("form.zig").parse(allocator, self.body);
    }
};

pub fn renderView(
    allocator: std.mem.Allocator,
    req: *Request,
    view_tmpl: []const u8,
    data: anytype,
) !Response {
    const is_htmx = req.headers.get("HX-Request") != null;

    if (is_htmx) {
        const html = try template.renderBlock(view_tmpl, "content", data, allocator);
        return Response.html(allocator, html);
    }

    if (req._app) |app| {
        if (app.layout) |layout| {
            const tmpl = try std.mem.concat(allocator, u8, &.{ layout, view_tmpl });
            defer allocator.free(tmpl);
            const html = try template.renderBlock(tmpl, "base", data, allocator);
            return Response.html(allocator, html);
        }
    }

    const html = try template.render(view_tmpl, data, allocator);
    return Response.html(allocator, html);
}

pub const Response = struct {
    status: Status,
    headers: Headers,
    body: ?[]const u8,
    allocator: ?std.mem.Allocator = null,
    body_allocated: bool = false,

    pub fn init() Response {
        return .{
            .status = .ok,
            .headers = Headers.init(),
            .body = null,
            .allocator = null,
            .body_allocated = false,
        };
    }

    pub fn deinit(self: *Response) void {
        const alloc = self.allocator orelse return;
        self.headers.map.deinit(alloc);
        if (self.body_allocated) {
            if (self.body) |b| alloc.free(b);
        }
    }

    pub fn json(allocator: std.mem.Allocator, value: anytype) !Response {
        var res = Response.init();
        res.allocator = allocator;
        try res.headers.set(allocator, "content-type", "application/json");
        res.body = try std.json.Stringify.valueAlloc(allocator, value, .{});
        res.body_allocated = true;
        return res;
    }

    pub fn html(allocator: std.mem.Allocator, content: []const u8) !Response {
        var res = Response.init();
        res.allocator = allocator;
        try res.headers.set(allocator, "content-type", "text/html");
        res.body = content;
        return res;
    }

    pub fn text(allocator: std.mem.Allocator, content: []const u8) !Response {
        var res = Response.init();
        res.allocator = allocator;
        try res.headers.set(allocator, "content-type", "text/plain");
        res.body = content;
        return res;
    }

    pub fn redirect(allocator: std.mem.Allocator, location: []const u8) !Response {
        var res = Response.init();
        res.allocator = allocator;
        res.status = .found;
        try res.headers.set(allocator, "Location", location);
        return res;
    }

    pub fn render(allocator: std.mem.Allocator, tmpl: []const u8, data: anytype) !Response {
        const rendered = try template.render(tmpl, data, allocator);
        return Response.html(allocator, rendered);
    }

    pub fn withStatus(self: *Response, status: Status) *Response {
        self.status = status;
        return self;
    }
};

pub fn render(allocator: std.mem.Allocator, tmpl: []const u8, data: anytype) !Response {
    const rendered = try template.render(tmpl, data, allocator);
    return Response.html(allocator, rendered);
}

pub const Handler = *const fn (allocator: std.mem.Allocator, req: *Request) anyerror!Response;

pub const NextFn = *const fn (std.mem.Allocator, *Request) anyerror!Response;

pub const MiddlewareFn = *const fn (std.mem.Allocator, *Request, NextFn) anyerror!Response;

const MAX_MIDDLEWARES = 16;

pub const AppConfig = struct {
    layout: ?[]const u8 = null,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    router: Route.Router,
    middlewares: [MAX_MIDDLEWARES]MiddlewareFn,
    middleware_count: usize,
    layout: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, config: AppConfig) !*App {
        const app = try allocator.create(App);
        app.* = .{
            .allocator = allocator,
            .router = try Route.Router.init(allocator),
            .middlewares = undefined,
            .middleware_count = 0,
            .layout = config.layout,
        };

        _ = @import("metrics.zig"); // Ensure metrics are initialized
        try app.registerDashboardRoutes();

        return app;
    }

    fn registerDashboardRoutes(self: *App) !void {
        const dashboard = @import("dashboard.zig");
        try self.router.add(.get, "/_spider/metrics", dashboard.metricsHandler);
        try self.router.add(.get, "/_spider/dashboard", dashboard.dashboardHandler);
        try self.router.add(.get, "/_spider/dashboard/panel", dashboard.dashboardPanelHandler);
    }

    pub fn deinit(self: *App) void {
        self.router.deinit();
        self.allocator.destroy(self);
    }

    pub fn use(self: *App, middleware: MiddlewareFn) !void {
        if (self.middleware_count < MAX_MIDDLEWARES) {
            self.middlewares[self.middleware_count] = middleware;
            self.middleware_count += 1;
        }
    }

    pub fn get(self: *App, path: []const u8, handler: Handler) !void {
        try self.router.add(.get, path, handler);
    }

    pub fn post(self: *App, path: []const u8, handler: Handler) !void {
        try self.router.add(.post, path, handler);
    }

    pub fn put(self: *App, path: []const u8, handler: Handler) !void {
        try self.router.add(.put, path, handler);
    }

    pub fn delete(self: *App, path: []const u8, handler: Handler) !void {
        try self.router.add(.delete, path, handler);
    }

    pub fn group(self: *App, prefix: []const u8) Route.Group {
        return self.router.group(prefix);
    }

    pub fn dispatch(self: *App, allocator: std.mem.Allocator, request: *Request) !Response {
        std.debug.print("WEB: dispatch method={s} path={s}\n", .{ @tagName(request.method), request.path });

        // Debug: Check if router has any routes
        std.debug.print("WEB: Router has {} static routes\n", .{self.router.static_routes.count()});

        const match_result = self.router.match(request.method, request.path, allocator) catch |err| {
            std.debug.print("WEB: router.match error: {}\n", .{err});
            return err;
        };

        const result = match_result orelse {
            std.debug.print("WEB: No route matched for {s} {s}\n", .{ @tagName(request.method), request.path });
            var res = try Response.text(allocator, "Not Found");
            res.status = .not_found;
            return res;
        };
        std.debug.print("WEB: Route matched!\n", .{});

        request.params = result.params;
        request._app = self;
        request._handler = result.handler;
        request._middleware_index = 0;

        return try self.runChain(allocator, request);
    }

    fn runChain(self: *App, allocator: std.mem.Allocator, req: *Request) !Response {
        if (req._middleware_index >= self.middleware_count) {
            std.debug.print("WEB: Calling handler\n", .{});
            return try req._handler.?(allocator, req);
        }

        const middleware = self.middlewares[req._middleware_index];
        req._middleware_index += 1;

        return try middleware(allocator, req, runChainWrapper);
    }

    fn runChainWrapper(allocator: std.mem.Allocator, req: *Request) !Response {
        const app = req._app.?;
        return try app.runChain(allocator, req);
    }
};

pub fn corsMiddleware(allocator: std.mem.Allocator, req: *Request, next: NextFn) !Response {
    var res = try next(allocator, req);
    try res.headers.set(allocator, "Access-Control-Allow-Origin", "*");
    try res.headers.set(allocator, "Access-Control-Allow-Methods", "GET,POST,PUT,DELETE");
    return res;
}

pub fn loggerMiddleware(allocator: std.mem.Allocator, req: *Request, next: NextFn) !Response {
    std.debug.print("[{s}] {s}\n", .{ @tagName(req.method), req.path });
    return try next(allocator, req);
}

pub fn authMiddleware(allocator: std.mem.Allocator, req: *Request, next: NextFn) !Response {
    const key = req.header("x-api-key");
    _ = key;
    return try next(allocator, req);
}

test "redirect response" {
    var res = try Response.redirect(std.heap.page_allocator, "/dashboard");
    defer res.deinit();
    try std.testing.expectEqual(res.status, .found);
    try std.testing.expectEqualStrings(res.headers.get("Location").?, "/dashboard");
}

test "render helper" {
    const Product = struct { name: []const u8 };
    var res = try render(std.heap.page_allocator, "Hello {{ name }}!", Product{ .name = "Widget" });
    defer res.deinit();
    try std.testing.expectEqualStrings(res.body.?, "Hello Widget!");
}

test "renderView with HX-Request header renders content block" {
    const tmpl =
        \\{% block "base" %}<!DOCTYPE html><html><body><div id="content">{% template "content" %}</div></body></html>{% end %}
        \\{% block "content" %}Partial Content{% end %}
    ;

    const app = try App.init(std.heap.page_allocator, .{});
    defer app.deinit();

    var req = Request{
        .method = .post,
        .path = "/test",
        .query = null,
        .headers = Headers.init(),
        .body = null,
        .params = .{},
        ._app = app,
    };
    defer req.deinit(std.heap.page_allocator);
    try req.headers.set(std.heap.page_allocator, "HX-Request", "true");

    var res = try renderView(std.heap.page_allocator, &req, tmpl, .{});
    defer res.deinit();
    try std.testing.expectEqualStrings(res.body.?, "Partial Content");
}

test "renderView without HX-Request header renders base block" {
    const tmpl =
        \\{% block "base" %}<!DOCTYPE html><html><body><div id="content">{% template "content" %}</div></body></html>{% end %}
        \\{% block "content" %}Partial Content{% end %}
    ;

    const app = try App.init(std.heap.page_allocator, .{});
    defer app.deinit();

    var req = Request{
        .method = .get,
        .path = "/test",
        .query = null,
        .headers = Headers.init(),
        .body = null,
        .params = .{},
        ._app = app,
    };
    defer req.deinit(std.heap.page_allocator);

    var res = try renderView(std.heap.page_allocator, &req, tmpl, .{});
    defer res.deinit();
    try std.testing.expectEqualStrings(res.body.?, "<!DOCTYPE html><html><body><div id=\"content\">Partial Content</div></body></html>");
}

test "renderView with layout + normal request renders base with layout prepended" {
    const layout =
        \\{% block "base" %}<!DOCTYPE html><html><body><main>{% template "content" %}</main></body></html>{% end %}
    ;
    const view =
        \\{% block "content" %}Hello World{% end %}
    ;

    const tmpl = try std.mem.concat(std.heap.page_allocator, u8, &.{ layout, view });
    defer std.heap.page_allocator.free(tmpl);

    const app = try App.init(std.heap.page_allocator, .{ .layout = layout });
    defer app.deinit();

    var req = Request{
        .method = .get,
        .path = "/test",
        .query = null,
        .headers = Headers.init(),
        .body = null,
        .params = .{},
        ._app = app,
    };
    defer req.deinit(std.heap.page_allocator);

    var res = try renderView(std.heap.page_allocator, &req, view, .{});
    defer res.deinit();
    try std.testing.expectEqualStrings(res.body.?, "<!DOCTYPE html><html><body><main>Hello World</main></body></html>");
}

test "renderView with layout + HTMX request renders content block only" {
    const layout =
        \\{% block "base" %}<!DOCTYPE html><html><body><main>{% template "content" %}</main></body></html>{% end %}
    ;
    const view =
        \\{% block "content" %}Hello World{% end %}
    ;

    const app = try App.init(std.heap.page_allocator, .{ .layout = layout });
    defer app.deinit();

    var req = Request{
        .method = .post,
        .path = "/test",
        .query = null,
        .headers = Headers.init(),
        .body = null,
        .params = .{},
        ._app = app,
    };
    defer req.deinit(std.heap.page_allocator);
    try req.headers.set(std.heap.page_allocator, "HX-Request", "true");

    var res = try renderView(std.heap.page_allocator, &req, view, .{});
    defer res.deinit();
    try std.testing.expectEqualStrings(res.body.?, "Hello World");
}

test "renderView without layout + normal request renders view directly" {
    const view = "Hello {{ name }}!";

    const app = try App.init(std.heap.page_allocator, .{});
    defer app.deinit();

    var req = Request{
        .method = .get,
        .path = "/test",
        .query = null,
        .headers = Headers.init(),
        .body = null,
        .params = .{},
        ._app = app,
    };
    defer req.deinit(std.heap.page_allocator);

    var res = try renderView(std.heap.page_allocator, &req, view, .{ .name = "World" });
    defer res.deinit();
    try std.testing.expectEqualStrings(res.body.?, "Hello World!");
}
