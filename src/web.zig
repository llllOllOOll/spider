const std = @import("std");

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
        res.body = try std.json.stringifyAlloc(allocator, value, .{});
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

pub const App = struct {
    allocator: std.mem.Allocator,
    routes: std.StringHashMap(Handler),

    pub fn init(allocator: std.mem.Allocator) !*App {
        const app = try allocator.create(App);
        app.* = .{
            .allocator = allocator,
            .routes = std.StringHashMap(Handler).init(allocator),
        };
        return app;
    }

    pub fn deinit(self: *App) void {
        var it = self.routes.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.routes.deinit();
        self.allocator.destroy(self);
    }

    fn routeKey(self: *App, method: Method, path: []const u8) ![]u8 {
        const m = @tagName(method);
        const key = try self.allocator.alloc(u8, m.len + 1 + path.len);
        @memcpy(key[0..m.len], m);
        key[m.len] = '/';
        @memcpy(key[m.len + 1 ..], path);
        return key;
    }

    pub fn get(self: *App, path: []const u8, handler: Handler) !void {
        const key = try self.routeKey(.get, path);
        try self.routes.put(key, handler);
    }

    pub fn post(self: *App, path: []const u8, handler: Handler) !void {
        const key = try self.routeKey(.post, path);
        try self.routes.put(key, handler);
    }

    pub fn put(self: *App, path: []const u8, handler: Handler) !void {
        const key = try self.routeKey(.put, path);
        try self.routes.put(key, handler);
    }

    pub fn delete(self: *App, path: []const u8, handler: Handler) !void {
        const key = try self.routeKey(.delete, path);
        try self.routes.put(key, handler);
    }

    pub fn dispatch(self: *App, allocator: std.mem.Allocator, request: *Request) !Response {
        const key = try self.routeKey(request.method, request.path);
        defer self.allocator.free(key);

        const handler = self.routes.get(key) orelse {
            var res = try Response.text(allocator, "Not Found");
            res.status = .not_found;
            return res;
        };

        return try handler(allocator, request);
    }
};
