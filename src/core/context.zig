const std = @import("std");
const template = @import("../render/template.zig");
const Database = @import("database.zig").Database;
pub const DatabaseCtx = @import("database.zig").DatabaseCtx;

pub const NextFn = *const fn (*Ctx) anyerror!Response;
pub const MiddlewareFn = *const fn (*Ctx, NextFn) anyerror!Response;
pub const ErrorHandler = *const fn (*Ctx, anyerror) anyerror!Response;

pub const CookieOptions = struct {
    value: []const u8 = "",
    http_only: bool = true,
    secure: bool = true,
    same_site: []const u8 = "Lax",
    path: []const u8 = "/",
    max_age: ?u32 = null,
};

pub const ResponseOptions = struct {
    status: std.http.Status = .ok,
    headers: []const [2][]const u8 = &.{},
    cookies: []const [2][]const u8 = &.{}, // .{ name, full_set_cookie_string }
};

pub const Response = struct {
    status: std.http.Status = .ok,
    body: ?[]const u8 = null,
    content_type: []const u8 = "text/plain",
    headers: []const [2][]const u8 = &.{},
    cookies: []const [2][]const u8 = &.{},
};

pub const Ctx = struct {
    request: std.http.Server.Request,
    arena: std.mem.Allocator,
    params: std.StringHashMapUnmanaged([]const u8),
    body: ?[]const u8 = null,
    _db: ?*const Database = null,

    pub fn db(self: *Ctx) DatabaseCtx {
        return .{ ._db = self._db.?, ._arena = self.arena };
    }

    pub fn json(self: *Ctx, value: anytype, opts: ResponseOptions) !Response {
        const body = try std.json.Stringify.valueAlloc(self.arena, value, .{});
        return Response{
            .status = opts.status,
            .body = body,
            .content_type = "application/json",
            .headers = opts.headers,
            .cookies = opts.cookies,
        };
    }

    pub fn text(_: *Ctx, content: []const u8, opts: ResponseOptions) !Response {
        return Response{
            .status = opts.status,
            .body = content,
            .content_type = "text/plain",
            .headers = opts.headers,
            .cookies = opts.cookies,
        };
    }

    pub fn html(_: *Ctx, content: []const u8, opts: ResponseOptions) !Response {
        return Response{
            .status = opts.status,
            .body = content,
            .content_type = "text/html; charset=utf-8",
            .headers = opts.headers,
            .cookies = opts.cookies,
        };
    }

    pub fn render(self: *Ctx, tmpl: []const u8, data: anytype, opts: ResponseOptions) !Response {
        const html_body = try template.render(tmpl, data, self.arena);
        return Response{
            .status = opts.status,
            .body = html_body,
            .content_type = "text/html; charset=utf-8",
            .headers = opts.headers,
            .cookies = opts.cookies,
        };
    }

    pub fn getBody(self: *Ctx) ?[]const u8 {
        return self.body;
    }

    pub fn bodyJson(self: *Ctx, comptime T: type) !T {
        const raw = self.body orelse return error.BodyEmpty;
        const parsed = try std.json.parseFromSlice(T, self.arena, raw, .{
            .ignore_unknown_fields = true,
        });
        return parsed.value;
    }

    pub fn isHtmx(self: *Ctx) bool {
        return self.header("HX-Request") != null;
    }

    pub fn isBoosted(self: *Ctx) bool {
        return self.header("HX-Boosted") != null;
    }

    pub fn cookie(self: *Ctx, name: []const u8) ?[]const u8 {
        const cookie_header = self.header("Cookie") orelse return null;
        var iter = std.mem.splitScalar(u8, cookie_header, ';');
        while (iter.next()) |pair| {
            const trimmed = std.mem.trim(u8, pair, " ");
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
                const key = std.mem.trim(u8, trimmed[0..eq], " ");
                if (std.mem.eql(u8, key, name)) {
                    return std.mem.trim(u8, trimmed[eq + 1 ..], " ");
                }
            }
        }
        return null;
    }

    pub fn withCookie(self: *Ctx, name: []const u8, value: []const u8, opts: CookieOptions) !ResponseOptions {
        const cookie_str = try self.setCookie(name, value, opts);
        const headers = try self.arena.alloc([2][]const u8, 1);
        headers[0] = .{ "Set-Cookie", cookie_str };
        return ResponseOptions{ .headers = headers };
    }

    pub fn setCookie(
        self: *Ctx,
        name: []const u8,
        value: []const u8,
        opts: CookieOptions,
    ) ![]const u8 {
        if (opts.max_age) |age| {
            return std.fmt.allocPrint(
                self.arena,
                "{s}={s}; Path={s}; Max-Age={d}; SameSite={s}{s}{s}",
                .{
                    name,
                    value,
                    opts.path,
                    age,
                    opts.same_site,
                    if (opts.http_only) "; HttpOnly" else "",
                    if (opts.secure) "; Secure" else "",
                },
            );
        }
        return std.fmt.allocPrint(
            self.arena,
            "{s}={s}; Path={s}; SameSite={s}{s}{s}",
            .{
                name,
                value,
                opts.path,
                opts.same_site,
                if (opts.http_only) "; HttpOnly" else "",
                if (opts.secure) "; Secure" else "",
            },
        );
    }

    pub fn query(self: *Ctx, name: []const u8) ?[]const u8 {
        const q = self.request.head.target;
        const start = std.mem.indexOfScalar(u8, q, '?') orelse return null;
        var iter = std.mem.splitScalar(u8, q[start + 1 ..], '&');
        while (iter.next()) |pair| {
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                if (std.mem.eql(u8, pair[0..eq], name)) {
                    return pair[eq + 1 ..];
                }
            }
        }
        return null;
    }

    pub fn header(self: *Ctx, name: []const u8) ?[]const u8 {
        var iter = self.request.iterateHeaders();
        while (iter.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) {
                return h.value;
            }
        }
        return null;
    }

    pub fn redirect(_: *Ctx, url: []const u8) !Response {
        return Response{
            .status = .found,
            .body = null,
            .content_type = "text/plain",
            .headers = &.{
                .{ "Location", url },
            },
        };
    }

    pub fn getPath(self: *Ctx) []const u8 {
        return self.request.head.target;
    }

    pub fn getMethod(self: *Ctx) []const u8 {
        return @tagName(self.request.head.method);
    }
};
