const std = @import("std");
const template = @import("../render/template.zig");
const views_mod = @import("../render/views.zig");
const Database = @import("database.zig").Database;
const DriverType = @import("database.zig").DriverType;
pub const DatabaseCtx = @import("database.zig").DatabaseCtx;

const root = @import("root");
const has_embed = @hasDecl(root, "spider_templates");

pub const ViewsMode = enum { runtime, embed };

pub const ViewsConfig = struct {
    views_dir: []const u8 = "./views",
    layout: ?[]const u8 = "layout",
    io: std.Io,
    arena: std.mem.Allocator,
    mode: ViewsMode = .runtime,
    index: ?*const views_mod.ViewsIndex = null,
};

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
    _driver_type: DriverType = .postgresql,
    _views: ?ViewsConfig = null,
    _io: std.Io = undefined,
    _headers: std.StringHashMapUnmanaged([]const u8) = .{},

    pub fn db(self: *Ctx) DatabaseCtx {
        return .{
            ._db = self._db.?,
            ._arena = self.arena,
            ._driver_type = self._driver_type,
        };
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

    pub fn view(self: *Ctx, name: []const u8, data: anytype, opts: ResponseOptions) !Response {
        const vc = self._views orelse return error.ViewsNotConfigured;

        const io = vc.io;

        if (has_embed) {
            const Templates = root.spider_templates;

            const view_content = blk: {
                var buf: [256]u8 = undefined;
                var j: usize = 0;
                for (name) |c| {
                    buf[j] = if (c == '/' or c == '-') '_' else c;
                    j += 1;
                }
                const normalized = buf[0..j];
                inline for (std.meta.fields(Templates)) |field| {
                    if (std.mem.eql(u8, field.name, normalized)) {
                        const instance: Templates = .{};
                        break :blk @field(instance, field.name);
                    }
                }
                return error.TemplateNotFound;
            };

            const has_extends = std.mem.indexOf(u8, view_content, "{% extends") != null;

            const rendered_html = if (has_extends) blk: {
                const layout_name = extractExtendsName(view_content) orelse return error.InvalidTemplate;

                const layout_content = blk2: {
                    var buf: [256]u8 = undefined;
                    var j: usize = 0;
                    for (layout_name) |c| {
                        buf[j] = if (c == '/' or c == '-') '_' else c;
                        j += 1;
                    }
                    const normalized = buf[0..j];
                    inline for (std.meta.fields(Templates)) |field| {
                        if (std.mem.eql(u8, field.name, normalized)) {
                            const instance: Templates = .{};
                            break :blk2 @field(instance, field.name);
                        }
                    }
                    return error.LayoutNotFound;
                };

                const combined = try std.mem.concat(self.arena, u8, &.{ layout_content, view_content });
                const block_name = if (self.isHtmx()) "content" else "base";
                break :blk try template.renderBlockWithTemplates(combined, block_name, data, self.arena, Templates{});
            } else blk: {
                break :blk try template.render(view_content, data, self.arena);
            };

            return Response{
                .status = opts.status,
                .body = rendered_html,
                .content_type = "text/html; charset=utf-8",
                .headers = opts.headers,
            };
        }

        const view_path = if (vc.index) |idx|
            idx.get(name) orelse return error.TemplateNotFound
        else
            try std.fmt.allocPrint(self.arena, "{s}/{s}.html", .{ vc.views_dir, name });

        const view_content = std.Io.Dir.cwd().readFileAlloc(
            io,
            view_path,
            self.arena,
            .limited(512 * 1024),
        ) catch |err| {
            if (err == error.FileNotFound) return error.TemplateNotFound;
            return err;
        };

        const has_extends = std.mem.indexOf(u8, view_content, "{% extends") != null;

        const rendered = if (has_extends) blk: {
            const layout_name = extractExtendsName(view_content) orelse return error.InvalidTemplate;

            const layout_path = if (vc.index) |idx|
                idx.get(layout_name) orelse return error.LayoutNotFound
            else
                try std.fmt.allocPrint(self.arena, "{s}/{s}.html", .{ vc.views_dir, layout_name });

            const layout_content = std.Io.Dir.cwd().readFileAlloc(
                io,
                layout_path,
                self.arena,
                .limited(512 * 1024),
            ) catch |err| {
                if (err == error.FileNotFound) return error.LayoutNotFound;
                return err;
            };

            const combined = try std.mem.concat(self.arena, u8, &.{ layout_content, view_content });
            const block_name = if (self.isHtmx()) "content" else "base";

            // Build template entries slice for includes (runtime mode)
            const TemplateEntry = struct { name: []const u8, content: []const u8 };
            var entries: std.ArrayList(TemplateEntry) = .empty;
            defer {
                for (entries.items) |entry| {
                    self.arena.free(entry.name);
                    self.arena.free(entry.content);
                }
                entries.deinit(self.arena);
            }

            // Normalize layout_name
            const layout_norm = blk_l: {
                var buf2: [256]u8 = undefined;
                var j2: usize = 0;
                for (layout_name) |c| {
                    buf2[j2] = if (c == '/' or c == '-') '_' else c;
                    j2 += 1;
                }
                break :blk_l try self.arena.dupe(u8, buf2[0..j2]);
            };
            try entries.append(self.arena, .{ .name = layout_norm, .content = layout_content });

            // Normalize view name
            const view_norm = blk_v: {
                var buf2: [256]u8 = undefined;
                var j2: usize = 0;
                for (name) |c| {
                    buf2[j2] = if (c == '/' or c == '-') '_' else c;
                    j2 += 1;
                }
                break :blk_v try self.arena.dupe(u8, buf2[0..j2]);
            };
            try entries.append(self.arena, .{ .name = view_norm, .content = view_content });

            // Load all templates from index for includes
            if (vc.index) |idx| {
                for (idx.entries) |entry| {
                    const content = std.Io.Dir.cwd().readFileAlloc(
                        io,
                        entry.path,
                        self.arena,
                        .limited(512 * 1024),
                    ) catch continue;
                    try entries.append(self.arena, .{ .name = try self.arena.dupe(u8, entry.name), .content = content });
                }
            }

            break :blk try template.renderBlockWithTemplates(combined, block_name, data, self.arena, entries.items);
        } else blk: {
            break :blk try template.render(view_content, data, self.arena);
        };

        return Response{
            .status = opts.status,
            .body = rendered,
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

    pub fn parseForm(self: *Ctx, comptime T: type) !T {
        const body = self.body orelse return error.BodyEmpty;
        var parser = try @import("../binding/form_parser.zig").FormParser.init(self.arena, body);
        defer parser.deinit();
        return try parser.parse(T);
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
        var iter = self._headers.iterator();
        while (iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) {
                return entry.value_ptr.*;
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

fn extractExtendsName(content: []const u8) ?[]const u8 {
    const marker = "{% extends \"";
    const start = std.mem.indexOf(u8, content, marker) orelse return null;
    const name_start = start + marker.len;
    const name_end = std.mem.indexOf(u8, content[name_start..], "\"") orelse return null;
    return content[name_start .. name_start + name_end];
}
