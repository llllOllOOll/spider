const std = @import("std");
const router = @import("router.zig");

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
        try self.map.put(allocator, name, value);
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

    pub fn queryParam(self: *const Request, name: []const u8) ?[]const u8 {
        const q = self.query orelse return null;
        var iter = std.mem.splitScalar(u8, q, '&');
        while (iter.next()) |pair| {
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
            }
        }
        return null;
    }

    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    pub fn param(self: *const Request, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }
};

pub const Response = struct {
    status: Status,
    headers: Headers,
    body: ?[]const u8,

    pub fn init() Response {
        return .{
            .status = .ok,
            .headers = Headers.init(),
            .body = null,
        };
    }

    pub fn json(allocator: std.mem.Allocator, value: anytype) !Response {
        var res = Response.init();
        try res.headers.set(allocator, "content-type", "application/json");
        res.body = try std.json.Stringify.valueAlloc(allocator, value, .{});
        return res;
    }

    pub fn html(allocator: std.mem.Allocator, content: []const u8) !Response {
        var res = Response.init();
        try res.headers.set(allocator, "content-type", "text/html");
        res.body = content;
        return res;
    }

    pub fn text(allocator: std.mem.Allocator, content: []const u8) !Response {
        var res = Response.init();
        try res.headers.set(allocator, "content-type", "text/plain");
        res.body = content;
        return res;
    }

    pub fn withStatus(self: *Response, status: Status) *Response {
        self.status = status;
        return self;
    }
};

pub const Handler = *const fn (allocator: std.mem.Allocator, req: *Request) anyerror!Response;

pub const MiddlewareFn = *const fn (std.mem.Allocator, *Request, *App, Handler, usize) anyerror!Response;

const MAX_MIDDLEWARES = 16;

pub const App = struct {
    allocator: std.mem.Allocator,
    router: router.Router,
    middlewares: [MAX_MIDDLEWARES]MiddlewareFn,
    middleware_count: usize,

    pub fn init(allocator: std.mem.Allocator) !*App {
        const app = try allocator.create(App);
        app.* = .{
            .allocator = allocator,
            .router = try router.Router.init(allocator),
            .middlewares = undefined,
            .middleware_count = 0,
        };
        return app;
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

    pub fn dispatch(self: *App, allocator: std.mem.Allocator, request: *Request) !Response {
        const match_result = self.router.match(request.method, request.path, allocator) catch |err| {
            std.debug.print("WEB: router.match error: {}\n", .{err});
            return err;
        };

        const result = match_result orelse {
            var res = try Response.text(allocator, "Not Found");
            res.status = .not_found;
            return res;
        };

        request.params = result.params;

        return try self.runChain(allocator, request, result.handler, 0);
    }

    fn runChain(self: *App, allocator: std.mem.Allocator, req: *Request, handler: Handler, index: usize) !Response {
        if (index >= self.middleware_count) {
            return try handler(allocator, req);
        }
        const middleware = self.middlewares[index];
        return try middleware(allocator, req, self, handler, index + 1);
    }
};
