//! Speed - A fast, ergonomic web framework for Zig
//! Focused on great Developer Experience (DX) for developers coming from Go, Django, TypeScript

const std = @import("std");

pub const Template = @import("render/template.zig").Template;
/// Trusted markup for templates: `{ expr }` escapes everything else.
pub const RawHtml = @import("render/context.zig").RawHtml;
pub const Ctx = @import("core/context.zig").Ctx;
pub const NextFn = @import("core/context.zig").NextFn;
pub const MiddlewareFn = @import("core/context.zig").MiddlewareFn;
pub const ErrorHandler = @import("core/context.zig").ErrorHandler;
pub const Response = @import("core/context.zig").Response;
pub const statusForError = @import("core/context.zig").statusForError;
pub const Path = @import("core/extractors.zig").Path;
pub const Form = @import("core/extractors.zig").Form;
pub const Database = @import("core/database.zig").Database;
pub const DatabaseCtx = @import("core/context.zig").DatabaseCtx;
pub const Config = @import("internal/config.zig").Config;
pub const Env = @import("internal/config.zig").Env;
pub const app = @import("core/app.zig").app;
pub const appWithConfig = @import("core/app.zig").appWithConfig;
const server = @import("core/app.zig").server;
pub const Server = @import("core/app.zig").Server;
pub const ListenOptions = @import("core/app.zig").ListenOptions;
pub const StaticConfig = @import("core/app.zig").StaticConfig;
pub const Router = @import("routing/router.zig").Router;
pub const Group = @import("routing/group.zig").Group;
pub const websocket = @import("ws/websocket.zig");
pub const Hub = @import("ws/hub.zig").Hub;
pub const Ws = @import("ws/ws.zig").Ws;
pub const Sse = @import("ws/sse.zig").Sse;
pub const pg = @import("spider_pg");
pub const sqlite = @import("spider_sqlite");
pub const auth = @import("modules/auth/auth.zig");
pub const static = @import("modules/static.zig");
pub const dashboard = @import("modules/dashboard.zig");
pub const livereload = @import("modules/livereload.zig");
pub const health = @import("modules/health.zig");
pub const rbac = @import("modules/rbac.zig");
pub const r2 = @import("spider_r2");
pub const qrcode = @import("spider_qrcode");
pub const push = @import("modules/push.zig");
pub const logger = @import("modules/logger.zig").middleware;
/// Request logger with options (quiet paths, stream opens) — see modules/logger.zig.
pub const loggerWith = @import("modules/logger.zig").with;
/// std.log function with UTC timestamps: `pub const std_options: std.Options = .{ .logFn = spider.logFn };`
pub const logFn = @import("internal/logfmt.zig").logFn;
pub const gzip = @import("middlewares/gzip.zig").middleware;
pub const dbgRequest = @import("middlewares/dbg_request.zig").middleware;
pub const dbgResponse = @import("middlewares/dbg_response.zig").middleware;
pub const metrics = @import("internal/metrics.zig");
pub const env = @import("internal/env.zig");
pub const template = @import("render/template.zig");
pub const template_max_component_depth = @import("render/renderer.zig").max_component_depth;
pub const ast = @import("render/ast.zig");
pub const zmd = @import("render/zmd/zmd.zig");
pub const form = @import("binding/form.zig");
pub const form_parser = @import("binding/form_parser.zig");
pub const multipart = @import("binding/multipart.zig");
pub const MultipartData = multipart.MultipartData;
pub const UploadedFile = multipart.UploadedFile;
pub const google = @import("providers/google.zig");
pub const jwks = @import("providers/jwks.zig");
pub const clerk = @import("providers/clerk.zig");
pub const keycloak = @import("providers/keycloak.zig");
pub const http_client = @import("pacman");
pub const http_client_mtls = @import("core/http_client_mtls.zig");

var global_ws_hub: ?*Hub = null;

pub fn getWsHub() *Hub {
    return global_ws_hub.?;
}

pub fn initWsHub(allocator: std.mem.Allocator, io: std.Io) !void {
    global_ws_hub = try allocator.create(Hub);
    global_ws_hub.?.* = Hub.init(allocator, io);
}

pub fn deinitWsHub(allocator: std.mem.Allocator) void {
    if (global_ws_hub) |hub| {
        hub.deinit();
        allocator.destroy(hub);
        global_ws_hub = null;
    }
}

// `zig test`/`b.addTest` only discover `test` blocks written directly in the
// root file passed to it — NOT transitively through `@import`, even for
// declarations that are actually used (e.g. `pub const Hub =
// @import("ws/hub.zig").Hub;` above plucks just the `Hub` type — it doesn't
// force analysis of hub.zig's sibling `test` blocks). Without this,
// `zig build test` silently compiled and reported "0 tests passed" while
// every test block in every other file (hub.zig, sse.zig, multipart.zig,
// form.zig, push.zig, zmd.zig, template_test.zig — 138 tests total) never
// ran at all. `refAllDeclsRecursive` doesn't exist in this Zig version, and
// plain `refAllDecls` only walks one level — same mismatch as above. The
// fix (same pattern already used in pg_test_root.zig for the pg module):
// explicitly import each file as a whole container, which forces full
// analysis of it, including its test blocks.
test {
    _ = @import("ws/hub.zig");
    _ = @import("ws/sse.zig");
    _ = @import("binding/multipart.zig");
    _ = @import("binding/form.zig");
    _ = @import("modules/push.zig");
    _ = @import("render/zmd/zmd.zig");
    _ = @import("render/template_test.zig");
    _ = @import("render/template_safety_test.zig");
    _ = @import("core/watchdog.zig");
    _ = @import("core/context_test.zig");
    _ = @import("core/app_test.zig");
    _ = @import("routing/router_test.zig");
    _ = @import("modules/rbac_test.zig");
    _ = @import("internal/url.zig");
    _ = @import("internal/logfmt.zig");
    _ = @import("modules/logger.zig");
    _ = @import("core/http_client_mtls.zig");
}
