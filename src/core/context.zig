const std = @import("std");
const template_mod = @import("../render/template.zig");
const Template = template_mod.Template;
const views_mod = @import("../render/views.zig");
const Database = @import("database.zig").Database;
pub const DatabaseCtx = @import("database.zig").DatabaseCtx;
const zmd = @import("../render/zmd/zmd.zig");
const Hub = @import("../ws/hub.zig").Hub;
const Watchdog = @import("watchdog.zig").Watchdog;
const RouteMeta = @import("../routing/router.zig").RouteMeta;

const root = @import("root");
pub const has_embed = @hasDecl(root, "spider_templates");

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
    raw: bool = false,
};

pub const Ctx = struct {
    request: std.http.Server.Request,
    arena: std.mem.Allocator,
    params: std.StringHashMapUnmanaged([]const u8),
    body: ?[]const u8 = null,
    _db: ?*const Database = null,
    _views: ?ViewsConfig = null,
    _io: std.Io = undefined,
    _stream: std.Io.net.Stream = undefined,
    _headers: std.StringHashMapUnmanaged([]const u8) = .{},
    _decorations: ?*const anyopaque = null,
    _last_template: ?[]const u8 = null,
    _ws_hub: ?*Hub = null,
    _sse_hub: ?*Hub = null,
    /// Middleware chain position for THIS request (see app.zig runChain).
    /// Per-request, not threadlocal: under zio a middleware that does I/O
    /// before next() yields its fiber, and another request on the same
    /// thread would otherwise overwrite the chain and resume this one into
    /// the wrong handler.
    _chain_mws: []const MiddlewareFn = &.{},
    _chain_handler: ?*const fn (*Ctx) anyerror!Response = null,
    /// Correlation id for this request (see requestId()).
    _request_id: []const u8 = "",
    /// This connection's watchdog entry (deadlines), for SSE/WebSocket
    /// streams to bound their writes. Null outside Server.listen().
    _watch: ?*Watchdog.Entry = null,
    /// What the matched route declared (.public, .quiet_log, .allow_http,
    /// roles); defaults when no route matched.
    _route: RouteMeta = .{},
    /// Human-readable detail for the error the handler/extractor returned.
    _error_detail: ?[]const u8 = null,

    /// Id correlating every log line and the response of this request: the
    /// incoming `X-Request-Id` when it looks sane (e.g. set by a proxy),
    /// otherwise generated. Also sent back as the `X-Request-Id` header.
    pub fn requestId(self: *Ctx) []const u8 {
        return self._request_id;
    }

    /// Attach a human-readable reason to the error about to be returned
    /// (e.g. "invalid path param: id"); onError/default handling can show it.
    pub fn setErrorDetail(self: *Ctx, detail: []const u8) void {
        self._error_detail = detail;
    }

    pub fn errorDetail(self: *Ctx) ?[]const u8 {
        return self._error_detail;
    }

    /// True when the client expects JSON rather than HTML: an explicit
    /// `Accept: application/json`, or a script request (fetch/XHR:
    /// `Sec-Fetch-Dest: empty`) that isn't htmx. Lets an error handler answer
    /// fetch() callers with a parseable body instead of an HTML page.
    pub fn wantsJson(self: *Ctx) bool {
        if (self.header("Accept")) |accept| {
            if (std.mem.indexOf(u8, accept, "application/json") != null) return true;
        }
        if (self.isHtmx()) return false;
        const dest = self.header("Sec-Fetch-Dest") orelse return false;
        return std.mem.eql(u8, dest, "empty");
    }

    pub fn db(self: *Ctx) DatabaseCtx {
        return .{
            ._db = self._db.?,
            ._arena = self.arena,
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
            .content_type = "text/plain; charset=utf-8",
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
        var tmpl_instance = try Template.init(self.arena, tmpl);
        defer tmpl_instance.deinit();

        const html_body = try tmpl_instance.render(data, self.arena);
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

            // First, try to find the template in EmbeddedTemplates
            const view_content = blk: {
                var buf: [256]u8 = undefined;
                var j: usize = 0;
                for (name) |c| {
                    buf[j] = if (c == '/' or c == '-') '_' else c;
                    j += 1;
                }
                const normalized = buf[0..j];
                @setEvalBranchQuota(10000);
                inline for (@typeInfo(Templates).@"struct".field_names) |fname| {
                    if (std.mem.eql(u8, fname, normalized)) {
                        const instance: Templates = .{};
                        break :blk @field(instance, fname);
                    }
                }
                self._last_template = name;
                return error.TemplateNotFound;
            };

            // Check for -- doc signature - if present, convert and return directly (no template processing)
            if (std.mem.startsWith(u8, view_content, "-- doc")) {
                const md_body = view_content["-- doc".len..];
                const md_html = try zmd.parse(self.arena, md_body, zmd.Formatters{});
                return Response{
                    .status = opts.status,
                    .body = md_html,
                    .content_type = "text/html; charset=utf-8",
                    .headers = opts.headers,
                    .cookies = opts.cookies,
                };
            }

            self._last_template = name;

            var components = std.StringHashMapUnmanaged([]const u8){};

            const embed_inst: Templates = .{};
            @setEvalBranchQuota(10000);
            inline for (@typeInfo(Templates).@"struct".field_names) |fname| {
                const content: []const u8 = @field(embed_inst, fname);
                try components.put(self.arena, try self.arena.dupe(u8, fname), try self.arena.dupe(u8, content));
                if (comptime std.mem.startsWith(u8, fname, "components_")) {
                    const alias = fname["components_".len..];
                    try components.put(self.arena, try self.arena.dupe(u8, alias), try self.arena.dupe(u8, content));
                }
            }

            var tmpl_instance = try Template.init(self.arena, view_content);
            defer tmpl_instance.deinit();
            tmpl_instance.components = components;

            const rendered_html = try tmpl_instance.render(data, self.arena);

            return Response{
                .status = opts.status,
                .body = rendered_html,
                .content_type = "text/html; charset=utf-8",
                .headers = opts.headers,
                .cookies = opts.cookies,
            };
        }

        const view_path = if (vc.index) |idx|
            idx.get(name) orelse {
                self._last_template = name;
                return error.TemplateNotFound;
            }
        else
            try std.fmt.allocPrint(self.arena, "{s}/{s}.html", .{ vc.views_dir, name });

        const view_content = std.Io.Dir.cwd().readFileAlloc(
            io,
            view_path,
            self.arena,
            .limited(512 * 1024),
        ) catch |err| {
            if (err == error.FileNotFound) {
                self._last_template = name;
                return error.TemplateNotFound;
            }
            return err;
        };

        // Check for -- doc signature - if present, convert and return directly (no template processing)
        if (std.mem.startsWith(u8, view_content, "-- doc")) {
            const md_body = view_content["-- doc".len..];
            const md_html = try zmd.parse(self.arena, md_body, zmd.Formatters{});
            return Response{
                .status = opts.status,
                .body = md_html,
                .content_type = "text/html; charset=utf-8",
                .headers = opts.headers,
                .cookies = opts.cookies,
            };
        }

        var components = std.StringHashMapUnmanaged([]const u8){};

        if (vc.index) |idx| {
            for (idx.entries) |entry| {
                const content = std.Io.Dir.cwd().readFileAlloc(
                    io,
                    entry.path,
                    self.arena,
                    .limited(512 * 1024),
                ) catch continue;
                try components.put(self.arena, try self.arena.dupe(u8, entry.name), content);
                if (std.mem.startsWith(u8, entry.name, "components_")) {
                    const alias = entry.name["components_".len..];
                    try components.put(self.arena, try self.arena.dupe(u8, alias), try self.arena.dupe(u8, content));
                }
            }
        }

        var tmpl_instance = try Template.init(self.arena, view_content);
        defer tmpl_instance.deinit();
        tmpl_instance.components = components;

        const rendered = try tmpl_instance.render(data, self.arena);

        return Response{
            .status = opts.status,
            .body = rendered,
            .content_type = "text/html; charset=utf-8",
            .headers = opts.headers,
            .cookies = opts.cookies,
        };
    }
    pub fn viewFragment(self: *Ctx, template_name: []const u8, component_name: []const u8, data: anytype, opts: ResponseOptions) !Response {
        const vc = self._views orelse return error.ViewsNotConfigured;
        const io = vc.io;

        if (has_embed) {
            const Templates = root.spider_templates;

            const view_content = blk: {
                var buf: [256]u8 = undefined;
                var j: usize = 0;
                for (template_name) |c| {
                    buf[j] = if (c == '/' or c == '-') '_' else c;
                    j += 1;
                }
                const normalized = buf[0..j];
                @setEvalBranchQuota(10000);
                inline for (@typeInfo(Templates).@"struct".field_names) |fname| {
                    if (std.mem.eql(u8, fname, normalized)) {
                        const instance: Templates = .{};
                        break :blk @field(instance, fname);
                    }
                }
                self._last_template = template_name;
                return error.TemplateNotFound;
            };

            if (std.mem.startsWith(u8, view_content, "-- doc")) {
                const md_body = view_content["-- doc".len..];
                const md_html = try zmd.parse(self.arena, md_body, zmd.Formatters{});
                return Response{
                    .status = opts.status,
                    .body = md_html,
                    .content_type = "text/html; charset=utf-8",
                    .headers = opts.headers,
                    .cookies = opts.cookies,
                };
            }

            self._last_template = template_name;

            var components = std.StringHashMapUnmanaged([]const u8){};

            const embed_inst: Templates = .{};
            @setEvalBranchQuota(10000);
            inline for (@typeInfo(Templates).@"struct".field_names) |fname| {
                const content: []const u8 = @field(embed_inst, fname);
                try components.put(self.arena, try self.arena.dupe(u8, fname), try self.arena.dupe(u8, content));
                if (comptime std.mem.startsWith(u8, fname, "components_")) {
                    const alias = fname["components_".len..];
                    try components.put(self.arena, try self.arena.dupe(u8, alias), try self.arena.dupe(u8, content));
                }
            }

            var tmpl_instance = try Template.init(self.arena, view_content);
            defer tmpl_instance.deinit();
            tmpl_instance.components = components;

            const rendered_html = try tmpl_instance.renderFragment(component_name, data, self.arena);

            return Response{
                .status = opts.status,
                .body = rendered_html,
                .content_type = "text/html; charset=utf-8",
                .headers = opts.headers,
                .cookies = opts.cookies,
            };
        }

        const view_path = if (vc.index) |idx|
            idx.get(template_name) orelse {
                self._last_template = template_name;
                return error.TemplateNotFound;
            }
        else
            try std.fmt.allocPrint(self.arena, "{s}/{s}.html", .{ vc.views_dir, template_name });

        const view_content = std.Io.Dir.cwd().readFileAlloc(
            io,
            view_path,
            self.arena,
            .limited(512 * 1024),
        ) catch |err| {
            if (err == error.FileNotFound) {
                self._last_template = template_name;
                return error.TemplateNotFound;
            }
            return err;
        };

        if (std.mem.startsWith(u8, view_content, "-- doc")) {
            const md_body = view_content["-- doc".len..];
            const md_html = try zmd.parse(self.arena, md_body, zmd.Formatters{});
            return Response{
                .status = opts.status,
                .body = md_html,
                .content_type = "text/html; charset=utf-8",
                .headers = opts.headers,
                .cookies = opts.cookies,
            };
        }

        var components = std.StringHashMapUnmanaged([]const u8){};

        if (vc.index) |idx| {
            for (idx.entries) |entry| {
                const content = std.Io.Dir.cwd().readFileAlloc(
                    io,
                    entry.path,
                    self.arena,
                    .limited(512 * 1024),
                ) catch continue;
                try components.put(self.arena, try self.arena.dupe(u8, entry.name), content);
                if (std.mem.startsWith(u8, entry.name, "components_")) {
                    const alias = entry.name["components_".len..];
                    try components.put(self.arena, try self.arena.dupe(u8, alias), try self.arena.dupe(u8, content));
                }
            }
        }

        var tmpl_instance = try Template.init(self.arena, view_content);
        defer tmpl_instance.deinit();
        tmpl_instance.components = components;

        const rendered = try tmpl_instance.renderFragment(component_name, data, self.arena);

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

    pub fn parseMultipart(self: *Ctx) !@import("../binding/multipart.zig").MultipartData {
        const body = self.body orelse return error.BodyEmpty;
        const ct = self.header("content-type") orelse return error.MissingContentType;
        const boundary = (@import("../binding/multipart.zig").extractBoundary(ct)) orelse return error.InvalidBoundary;
        return @import("../binding/multipart.zig").parse(self.arena, body, boundary);
    }

    pub fn parseForm(self: *Ctx, comptime T: type) !T {
        const body = self.body orelse return error.BodyEmpty;
        const ct = self.header("content-type");
        if (ct) |content_type| {
            if (@import("../binding/multipart.zig").extractBoundary(content_type)) |boundary| {
                var mp = try @import("../binding/multipart.zig").parse(self.arena, body, boundary);
                defer mp.deinit();
                return try @import("../binding/form_parser.zig").FormParser.fromMultipartData(&mp, self.arena, T);
            }
        }
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

    /// Raw getter for the `HX-Request-Type` header, introduced in htmx 4.0.
    /// Confirmed values per the official htmx docs: `"partial"` (a fragment
    /// swap) or `"full"` (a full-page request, including boosted navigation
    /// and history restores). Returns `null` on htmx 2.x requests — that
    /// version never sends this header — and on non-htmx requests.
    ///
    /// This is a thin, unopinionated wrapper around `header()`, mirroring
    /// `isHtmx()`/`isBoosted()`. Most call sites should prefer `requestKind()`
    /// below, which already resolves the 2.x/4.0 difference for you.
    pub fn requestType(self: *Ctx) ?[]const u8 {
        return self.header("HX-Request-Type");
    }

    /// Consolidated classification of an htmx request, spanning both the
    /// 2.x header set (`HX-Request`, `HX-Boosted`) and the 4.0 header
    /// (`HX-Request-Type: partial|full`).
    pub const RequestKind = enum {
        /// A fragment/partial swap.
        /// - htmx 4.0: `HX-Request-Type: partial`.
        /// - htmx 2.x: `HX-Request` present and `HX-Boosted` absent.
        fragment,
        /// A boosted navigation (`hx-boost`) — an AJAX request that
        /// represents real navigation, not a UI fragment swap.
        /// - htmx 4.0 and 2.x: `HX-Boosted` present.
        boosted,
        /// A full, non-htmx request — direct navigation, refresh, or a
        /// plain (non-AJAX, non-boosted) link/form submission.
        /// - htmx 4.0: `HX-Request-Type: full`.
        /// - htmx 2.x: none of the htmx headers present.
        full,
    };

    /// Resolves `RequestKind` for the current request, automatically
    /// bridging htmx 2.x and 4.0: it checks `HX-Request-Type` (4.0) first,
    /// and falls back to the `HX-Request`/`HX-Boosted` header pair (2.x)
    /// when that header is absent. There is no `.history_restore` variant —
    /// htmx 4.0 removed the history-restore request case and always issues
    /// a full request for history navigation.
    ///
    /// `isHtmx()` and `isBoosted()` remain fully valid and are unaffected by
    /// this addition — `requestKind()` is a new convenience on top of them,
    /// not a replacement. Existing call sites using `isHtmx()`/`isBoosted()`
    /// keep working exactly as before.
    pub fn requestKind(self: *Ctx) RequestKind {
        if (self.requestType()) |rt| {
            if (std.mem.eql(u8, rt, "partial")) return .fragment;
            return .full;
        }
        if (self.isBoosted()) return .boosted;
        if (self.isHtmx()) return .fragment;
        return .full;
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

    /// The immediate TCP peer's address (no port), allocated in `arena`.
    ///
    /// Behind a reverse proxy, this is the proxy's address, not the
    /// original client's — `header("X-Forwarded-For")` is the right source
    /// in that case. This exists for the direct-connection case (no proxy
    /// in front, e.g. local dev or a LAN device hitting the server
    /// directly), where no proxy ever adds that header, and callers would
    /// otherwise have no way to identify who connected.
    pub fn peerAddress(self: *Ctx) ?[]const u8 {
        return switch (self._stream.socket.address) {
            .ip4 => |a| std.fmt.allocPrint(
                self.arena,
                "{d}.{d}.{d}.{d}",
                .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] },
            ) catch null,
            .ip6 => |a| std.fmt.allocPrint(
                self.arena,
                "{f}",
                .{std.Io.net.Ip6Address.Unresolved{ .bytes = a.bytes, .interface_name = null }},
            ) catch null,
        };
    }

    pub fn redirect(self: *Ctx, url: []const u8) !Response {
        const hdrs = try self.arena.alloc([2][]const u8, 1);
        hdrs[0] = .{ "Location", url };
        return Response{
            .status = .found,
            .body = null,
            .content_type = "text/plain",
            .headers = hdrs,
        };
    }

    pub fn wsHub(self: *Ctx) *Hub {
        return self._ws_hub orelse @panic("wsHub: no hub attached — use server.ws()");
    }

    pub fn sseHub(self: *Ctx) *Hub {
        return self._sse_hub orelse @panic("sseHub: no SSE hub — use server.sse()");
    }

    /// Retorna o org_id da primeira organization que o usuário tem a role especificada
    pub fn getOrgByRole(self: *Ctx, role: []const u8) ?[]const u8 {
        const count_str = self.params.get("_auth_orgs_count") orelse return null;
        const count = std.fmt.parseInt(usize, count_str, 10) catch return null;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const role_key = std.fmt.allocPrint(self.arena, "_auth_org_{d}_role", .{i}) catch return null;
            const r = self.params.get(role_key) orelse continue;
            if (std.mem.eql(u8, r, role)) {
                const id_key = std.fmt.allocPrint(self.arena, "_auth_org_{d}_id", .{i}) catch return null;
                return self.params.get(id_key);
            }
        }
        return null;
    }

    pub fn hasOrgRole(self: *Ctx, role: []const u8) bool {
        const count_str = self.params.get("_auth_orgs_count") orelse return false;
        const count = std.fmt.parseInt(usize, count_str, 10) catch return false;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const key = std.fmt.allocPrint(self.arena, "_auth_org_{d}_role", .{i}) catch return false;
            const r = self.params.get(key) orelse continue;
            if (std.mem.eql(u8, r, role)) return true;
        }
        return false;
    }

    /// Org the current request acts on, when one was selected — by the auth
    /// provider (`active_org_cookie`) or by an app middleware via
    /// `setActiveOrg`. Null means "no selection", not "no orgs".
    pub fn activeOrgId(self: *Ctx) ?[]const u8 {
        return self.params.get("_auth_active_org");
    }

    /// Marks `org_id` as the org this request acts on. `requireOrgRoles` and
    /// `hasActiveOrgRole` then only accept roles held in THIS org. Setting an
    /// org the user isn't a member of is allowed and simply grants no org role.
    pub fn setActiveOrg(self: *Ctx, org_id: []const u8) !void {
        try self.params.put(self.arena, "_auth_active_org", try self.arena.dupe(u8, org_id));
    }

    /// True when the token lists `org_id` among the user's organizations.
    pub fn isOrgMember(self: *Ctx, org_id: []const u8) bool {
        const count_str = self.params.get("_auth_orgs_count") orelse return false;
        const count = std.fmt.parseInt(usize, count_str, 10) catch return false;
        var key_buf: [64]u8 = undefined;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const key = std.fmt.bufPrint(&key_buf, "_auth_org_{d}_id", .{i}) catch return false;
            const id = self.params.get(key) orelse continue;
            if (std.mem.eql(u8, id, org_id)) return true;
        }
        return false;
    }

    /// True when the user holds `role` in the active org. With no active org
    /// selected, falls back to "in any of the user's orgs" (same as hasOrgRole).
    pub fn hasActiveOrgRole(self: *Ctx, role: []const u8) bool {
        return self.orgRoleIn(&.{role}, self.activeOrgId());
    }

    /// Shared by hasActiveOrgRole and rbac.requireOrgRoles: does any
    /// `_auth_org_{i}` entry (restricted to `org_filter` when non-null) carry
    /// one of `wanted`?
    pub fn orgRoleIn(self: *Ctx, wanted: []const []const u8, org_filter: ?[]const u8) bool {
        const count_str = self.params.get("_auth_orgs_count") orelse return false;
        const count = std.fmt.parseInt(usize, count_str, 10) catch return false;
        var key_buf: [64]u8 = undefined;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (org_filter) |want| {
                const id_key = std.fmt.bufPrint(&key_buf, "_auth_org_{d}_id", .{i}) catch return false;
                const id = self.params.get(id_key) orelse continue;
                if (!std.mem.eql(u8, id, want)) continue;
            }
            const role_key = std.fmt.bufPrint(&key_buf, "_auth_org_{d}_role", .{i}) catch return false;
            const r = self.params.get(role_key) orelse continue;
            for (wanted) |want_role| {
                if (std.mem.eql(u8, r, want_role)) return true;
            }
        }
        return false;
    }

    pub fn hasRole(self: *Ctx, role: []const u8) bool {
        const count_str = self.params.get("_auth_roles_count") orelse return false;
        const count = std.fmt.parseInt(usize, count_str, 10) catch return false;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const key = std.fmt.allocPrint(self.arena, "_auth_role_{d}", .{i}) catch return false;
            const r = self.params.get(key) orelse continue;
            if (std.mem.eql(u8, r, role)) return true;
        }
        return false;
    }

    // --- Identity: who the request is from, and what it may do ------------
    //
    // Auth providers fill these (jwks/keycloak/clerk from the token, the
    // HS256 `auth` middleware its user id); an app whose users or roles live
    // elsewhere (its database, a session, another IdP) fills them from its
    // own middleware, registered after the auth one. `.authenticated`,
    // `.roles`, `.org_roles` and policies read them the same way whatever
    // the source.

    pub const User = struct {
        id: []const u8,
        email: ?[]const u8 = null,
        name: ?[]const u8 = null,
    };

    /// Marks the request as coming from `user` (what `.authenticated` checks).
    pub fn setUser(self: *Ctx, user: User) !void {
        try self.params.put(self.arena, "_auth_sub", try self.arena.dupe(u8, user.id));
        if (user.email) |e| try self.params.put(self.arena, "_auth_email", try self.arena.dupe(u8, e));
        if (user.name) |n| try self.params.put(self.arena, "_auth_name", try self.arena.dupe(u8, n));
    }

    /// The logged-in user's id: the token's subject, or the HS256 `auth`
    /// middleware's user id. Null for an anonymous request.
    pub fn userId(self: *Ctx) ?[]const u8 {
        return self.params.get("_auth_sub") orelse self.params.get("_user_id");
    }

    /// Grants the user a role (what `.roles` and `hasRole` check).
    pub fn addRole(self: *Ctx, role: []const u8) !void {
        const n = self.authCount("_auth_roles_count");
        try self.params.put(self.arena, try std.fmt.allocPrint(self.arena, "_auth_role_{d}", .{n}), try self.arena.dupe(u8, role));
        try self.params.put(self.arena, "_auth_roles_count", try std.fmt.allocPrint(self.arena, "{d}", .{n + 1}));
    }

    /// Replaces the user's roles (e.g. the token's) with `list`.
    pub fn setRoles(self: *Ctx, list: []const []const u8) !void {
        try self.params.put(self.arena, "_auth_roles_count", "0");
        for (list) |r| try self.addRole(r);
    }

    /// The user's roles, in the order they were granted.
    pub fn roles(self: *Ctx) ![]const []const u8 {
        const n = self.authCount("_auth_roles_count");
        var out: std.ArrayList([]const u8) = .empty;
        for (0..n) |i| {
            const r = self.params.get(try std.fmt.allocPrint(self.arena, "_auth_role_{d}", .{i})) orelse continue;
            try out.append(self.arena, r);
        }
        return out.items;
    }

    pub const OrgRole = struct {
        org_id: []const u8,
        org_name: []const u8 = "",
        role: []const u8,
    };

    /// Grants the user a role inside an organization (what `.org_roles`,
    /// `isOrgMember` and `hasActiveOrgRole` check). One call per role.
    pub fn addOrgRole(self: *Ctx, r: OrgRole) !void {
        const n = self.authCount("_auth_orgs_count");
        const a = self.arena;
        try self.params.put(a, try std.fmt.allocPrint(a, "_auth_org_{d}_id", .{n}), try a.dupe(u8, r.org_id));
        try self.params.put(a, try std.fmt.allocPrint(a, "_auth_org_{d}_name", .{n}), try a.dupe(u8, r.org_name));
        try self.params.put(a, try std.fmt.allocPrint(a, "_auth_org_{d}_role", .{n}), try a.dupe(u8, r.role));
        try self.params.put(a, "_auth_orgs_count", try std.fmt.allocPrint(a, "{d}", .{n + 1}));
    }

    fn authCount(self: *Ctx, key: []const u8) usize {
        return std.fmt.parseInt(usize, self.params.get(key) orelse return 0, 10) catch 0;
    }

    /// The matched route's declarations (see routing/route_config.zig).
    pub fn route(self: *const Ctx) RouteMeta {
        return self._route;
    }

    pub fn getPath(self: *Ctx) []const u8 {
        return self.request.head.target;
    }

    pub fn getMethod(self: *Ctx) []const u8 {
        return @tagName(self.request.head.method);
    }
};

/// Default HTTP status for an error returned by a handler, middleware or
/// extractor. Used when the app has no `onError`, and exposed so an app's
/// own handler can fall back to it for errors it doesn't special-case.
pub fn statusForError(err: anyerror) std.http.Status {
    return switch (err) {
        error.NotFound => .not_found,
        error.Forbidden => .forbidden,
        error.Unauthorized => .unauthorized,
        // Client input: path/form/multipart/JSON that can't be bound, or that
        // app code rejected itself (error.BadRequest + c.setErrorDetail).
        error.BadRequest,
        error.MissingPathParam,
        error.InvalidPathParam,
        error.BodyEmpty,
        error.BodyUnreadable,
        error.MissingField,
        error.MissingFieldName,
        error.MissingContentType,
        error.InvalidBoundary,
        error.BoundaryTooLong,
        error.InvalidMultipartEncoding,
        error.SyntaxError,
        error.UnexpectedEndOfInput,
        error.UnexpectedToken,
        error.UnknownField,
        error.DuplicateField,
        error.InvalidNumber,
        error.InvalidEnumTag,
        => .bad_request,
        error.PayloadTooLarge => .payload_too_large,
        // Postgres (spider.pg typed errors). Input-shaped failures are the
        // client's; conflicts are 409; transient contention is 503 (retrying
        // helps); a trigger/plpgsql RAISE is a business rule (422).
        error.UniqueViolation,
        error.ForeignKeyViolation,
        error.ExclusionViolation,
        => .conflict,
        error.InvalidTextRepresentation,
        error.InvalidUUID,
        error.StringDataRightTruncation,
        error.NumericValueOutOfRange,
        error.InvalidDatetimeFormat,
        error.DatetimeFieldOverflow,
        error.NotNullViolation,
        error.CheckViolation,
        => .bad_request,
        error.RaisedException => .unprocessable_entity,
        error.SerializationFailure,
        error.DeadlockDetected,
        error.LockNotAvailable,
        error.QueryCanceled,
        => .service_unavailable,
        else => .internal_server_error,
    };
}
