//! Spider: a web framework for Zig. Router, middleware, templates, SSE and
//! WebSocket, sessions and auth providers, an HTTP client, and database
//! drivers (PostgreSQL, SQLite) behind build options.
//!
//! Everything an app uses is reached from here: `const spider = @import("spider");`.

const std = @import("std");

/// A template parsed from text, for rendering outside a request (an email
/// body, a file): `Template.init(allocator, text)`, then `render(data,
/// allocator)`. Inside a handler, `c.view` is the usual way.
pub const Template = @import("render/template.zig").Template;
/// Trusted markup for templates: `{ expr }` escapes everything else.
pub const RawHtml = @import("render/context.zig").RawHtml;
/// Test helpers for apps: `start` (requests against the running app),
/// `expectRoutes`, `expectConventions`, `expectAllTestsDiscovered`.
pub const testing = @import("testing.zig");
/// App conventions checked by `spider check` and testing.expectConventions().
pub const conventions = @import("conventions.zig");
/// The request, and what builds the response: every handler receives a `*Ctx`.
pub const Ctx = @import("core/context.zig").Ctx;
/// What a middleware calls to let the request go on.
pub const NextFn = @import("core/context.zig").NextFn;
/// A middleware: `fn (*spider.Ctx, spider.NextFn) !spider.Response`.
pub const MiddlewareFn = @import("core/context.zig").MiddlewareFn;
/// The function given to `server.onError`.
pub const ErrorHandler = @import("core/context.zig").ErrorHandler;
/// What a handler returns; built by `c.json`, `c.view`, `c.redirect` and the like.
pub const Response = @import("core/context.zig").Response;
/// Options of `c.download(bytes, .{ .filename = …, .content_type = … })`.
pub const DownloadOptions = @import("core/context.zig").DownloadOptions;
/// Content types for downloads: `.xlsx`, `.csv`, `.pdf`, `.binary`.
pub const content_types = @import("core/context.zig").content_types;
/// The HTTP status an error gets by default: `error.NotFound` is 404, and so on.
pub const statusForError = @import("core/context.zig").statusForError;
/// Handler parameter: a `:name` segment of the route, converted. `id: spider.Path(i64, "id")`.
pub const Path = @import("core/extractors.zig").Path;
/// Handler parameter: the submitted form as a struct. `form: spider.Form(Input)`.
pub const Form = @import("core/extractors.zig").Form;
/// Handler parameter: the resource the route's spider.resourcePolicy loaded.
pub const Loaded = @import("core/extractors.zig").Loaded;
// internal: the old generic database handle; apps use `spider.pg` or `spider.sqlite`.
pub const Database = @import("core/database.zig").Database;
// internal: see Database.
pub const DatabaseCtx = @import("core/context.zig").DatabaseCtx;
/// The app's settings: what `spider.config.zig` declares (port, host,
/// directories, timeouts, limits).
pub const Config = @import("internal/config.zig").Config;
/// The value of `Config.env`: `.development`, `.production` or `.testing`.
/// Nothing in Spider reads it today.
pub const Env = @import("internal/config.zig").Env;
/// Builds the server of an app: `var server = spider.app(.{});`.
pub const app = @import("core/app.zig").app;
/// The same server, with the config given in code instead of `spider.config.zig`.
pub const appWithConfig = @import("core/app.zig").appWithConfig;
const server = @import("core/app.zig").server;
/// The server type `spider.app` returns; its methods register routes and
/// middlewares, and `listen()` runs it.
pub const Server = @import("core/app.zig").Server;
/// The argument of `server.listen`: `.port` and `.host`, both optional.
pub const ListenOptions = @import("core/app.zig").ListenOptions;
/// A periodic task of a feature's `jobs`; `spider.every` builds one.
pub const Job = @import("core/app.zig").Job;
/// A job for a feature's `jobs`: `spider.every(60_000, run)` calls `run` once a minute.
pub const every = @import("core/app.zig").every;
/// What a feature's `boot()` receives: an allocator and the server's `Io`.
pub const Boot = @import("core/app.zig").Boot;
/// Where static files are served from.
pub const StaticConfig = @import("core/app.zig").StaticConfig;
// internal: the route table behind the server and each Group.
pub const Router = @import("routing/router.zig").Router;
/// The routes of one feature under one prefix: what a feature's `routes.build()` returns.
pub const Group = @import("routing/group.zig").Group;
// internal: WebSocket framing; handlers use `spider.Ws`.
pub const websocket = @import("ws/websocket.zig");
/// The connected SSE or WebSocket clients, and what sends to them: `emit`,
/// `emitTo` a channel, `broadcast`.
pub const Hub = @import("ws/hub.zig").Hub;
/// One WebSocket connection, as its handler sees it: `next()` reads a message, `send` writes one.
pub const Ws = @import("ws/ws.zig").Ws;
/// One Server-Sent Events stream, as its handler sees it.
pub const Sse = @import("ws/sse.zig").Sse;
/// PostgreSQL: `init`, `query`, `queryOne`, `queryExecute`, `begin`. Opt-in with `-Dpg=true`.
pub const pg = @import("spider_pg");
/// SQLite: `init`, `query`, `queryOne`, `queryExecute`, `begin`. Opt-in with `-Dsqlite=true`.
pub const sqlite = @import("spider_sqlite");
/// Tokens signed with a secret of the app (HS256) and the cookie helpers
/// around them. For a login with the app's own users, `spider.session` is
/// the ready-made one.
pub const auth = @import("modules/auth/auth.zig");
/// Login sessions for an app's own users: a signed cookie (or bearer
/// token), `start`, `end`, `middleware()`.
pub const session = @import("modules/session.zig");
/// Password hashing for an app's own users (argon2id): `hash`, `verify`.
pub const password = @import("modules/password.zig");
/// Static file serving; the server uses it by itself for the `static_dir` of the config.
pub const static = @import("modules/static.zig");
/// Browser reload under `spider dev` (the server wires it in by itself).
pub const dev_reload = @import("modules/dev_reload.zig");
/// The handlers behind `/up` and `/_spider/health`, which `spider.app` registers.
pub const health = @import("modules/health.zig");
/// The checks behind a route's `.roles`, `.org_roles`, `.authenticated` and
/// `.policy`, as middlewares.
pub const rbac = @import("modules/rbac.zig");
/// A named access rule for a route: `.policy = spider.policy("post_owner", isPostOwner)`
/// with `fn isPostOwner(c: *spider.Ctx) !bool`. See modules/rbac.zig.
pub const policy = rbac.policy;
/// What `spider.policy` and `spider.resourcePolicy` return: the value of a route's `.policy`.
pub const Policy = rbac.Policy;
/// A policy that loads the route's resource (404 when missing), checks it,
/// and hands it to the handler (spider.Loaded(T) / c.loaded(T)).
pub const resourcePolicy = rbac.resourcePolicy;
/// The rules about one kind of resource in one place (Laravel Policy /
/// Pundit): `Set.route(.update)` for routes, `Set.can(c, .update, x)` in handlers.
pub const policySet = rbac.policySet;
/// Cloudflare R2 (S3-compatible) object storage: `put`, `get`, `delete`,
/// presigned URLs. Opt-in with `-Dr2=true`.
pub const r2 = @import("spider_r2");
/// QR code generation. Opt-in with `-Dqrcode=true`.
pub const qrcode = @import("spider_qrcode");
/// Excel .xlsx files, written and read — opt-in with `-Dxlsx=true` (see
/// modules/xlsx/README.md).
pub const xlsx = @import("spider_xlsx");
/// Web Push notifications to browsers (VAPID).
pub const push = @import("modules/push.zig");
/// Sending mail through a provider's HTTP API (Brevo, Resend, Postmark) —
/// see modules/mail/mail.zig.
pub const mail = @import("modules/mail/mail.zig");
/// Middleware that logs one line per request: `server.use(spider.logger)`.
pub const logger = @import("modules/logger.zig").middleware;
/// Request logger with options (quiet paths, stream opens) — see modules/logger.zig.
pub const loggerWith = @import("modules/logger.zig").with;
/// std.log function with UTC timestamps:
/// `pub const std_options: std.Options = .{ .logFn = spider.logFn };`
pub const logFn = @import("internal/logfmt.zig").logFn;
/// Middleware that compresses response bodies of 1024 bytes or more for
/// clients that accept gzip.
pub const gzip = @import("middlewares/gzip.zig").middleware;
/// `spider.forceHttps(.{ .default_base_url = "https://example.com" })`: a
/// middleware that redirects plain HTTP to HTTPS behind a TLS proxy (honors
/// route .allow_http).
pub const forceHttps = @import("middlewares/https.zig").forceHttps;
/// Options of `spider.forceHttps`.
pub const ForceHttpsOptions = @import("middlewares/https.zig").Options;
/// Middleware that adds `Vary: HX-Request` to HTML responses.
pub const varyHtmx = @import("middlewares/vary.zig").varyHtmx;
/// `spider.errorHandler(.{})`: a ready-made onError that answers JSON, an
/// htmx toast or a page (see modules/errors.zig).
pub const errorHandler = @import("modules/errors.zig").errorHandler;
/// Tells Spider that `mw` authenticates requests (an app's own session
/// middleware); Spider's providers mark theirs. See modules/auth_marker.zig.
pub const markAuthMiddleware = @import("modules/auth_marker.zig").mark;
/// Options of `spider.errorHandler`.
pub const ErrorHandlerOptions = @import("modules/errors.zig").Options;
/// Middleware that prints each request (method, target, headers and body)
/// to stderr, for debugging.
pub const dbgRequest = @import("middlewares/dbg_request.zig").middleware;
/// Middleware that prints each response (status, headers and body) to
/// stderr, for debugging.
pub const dbgResponse = @import("middlewares/dbg_response.zig").middleware;
/// Environment variables, with `.env` loaded: `spider.env.getOr("NAME", "default")`.
pub const env = @import("internal/env.zig");
// internal: the template engine's file; apps use `spider.Template` and `c.view`.
pub const template = @import("render/template.zig");
// internal: how deep components may nest before a render fails.
pub const template_max_component_depth = @import("render/renderer.zig").max_component_depth;
// internal: the template engine's syntax tree.
pub const ast = @import("render/ast.zig");
/// Markdown to HTML: `spider.zmd.parse(arena, text, .{})`. What the author typed is escaped.
pub const zmd = @import("render/zmd/zmd.zig");
// internal: form parsing; handlers use `c.parseForm` or `spider.Form`.
pub const form = @import("binding/form.zig");
// internal: see form.
pub const form_parser = @import("binding/form_parser.zig");
/// `multipart/form-data` parsing: the fields and the uploaded files of a
/// form. Handlers use `c.parseMultipart`.
pub const multipart = @import("binding/multipart.zig");
/// The parsed parts of a multipart body: what `c.parseMultipart` returns.
pub const MultipartData = multipart.MultipartData;
/// One uploaded file of a multipart body: its name, content type and bytes.
pub const UploadedFile = multipart.UploadedFile;
/// Sign-in with Google (OAuth): `login` sends the visitor to Google,
/// `callback` checks the answer and returns their profile.
pub const google = @import("providers/google.zig");
/// Checks tokens signed by an identity provider, with the keys it publishes (JWKS).
pub const jwks = @import("providers/jwks.zig");
/// Authentication through Clerk.
pub const clerk = @import("providers/clerk.zig");
/// Authentication through a Keycloak realm: the login, callback and refresh
/// handlers, and the middleware that checks the token.
pub const keycloak = @import("providers/keycloak.zig");
/// The HTTP client: `get`, `post`, `put`, `patch`, `delete`, `head`, or a
/// `Client` that keeps connections.
pub const http_client = @import("pacman");
/// HTTP requests that present a client certificate (mutual TLS).
pub const http_client_mtls = @import("core/http_client_mtls.zig");

var global_ws_hub: ?*Hub = null;

// internal: a process-wide WebSocket hub from before routes had their own; use `c.wsHub()`.
pub fn getWsHub() *Hub {
    return global_ws_hub.?;
}

// internal: see getWsHub.
pub fn initWsHub(allocator: std.mem.Allocator, io: std.Io) !void {
    global_ws_hub = try allocator.create(Hub);
    global_ws_hub.?.* = Hub.init(allocator, io);
}

// internal: see getWsHub.
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
    _ = @import("render/embedded_test.zig");
    _ = @import("core/watchdog.zig");
    _ = @import("core/context_test.zig");
    _ = @import("core/download.zig");
    _ = @import("core/app_test.zig");
    _ = @import("core/origin_test.zig");
    _ = @import("core/client_ip.zig");
    _ = @import("modules/auth/auth.zig");
    _ = @import("modules/password.zig");
    _ = @import("modules/session.zig");
    _ = @import("modules/dev_reload.zig");
    _ = @import("routing/router_test.zig");
    _ = @import("modules/rbac_test.zig");
    _ = @import("internal/url.zig");
    _ = @import("internal/logfmt.zig");
    _ = @import("modules/logger.zig");
    _ = @import("modules/auth_marker.zig");
    _ = @import("routing/expect_routes.zig");
    _ = @import("conventions.zig");
    _ = @import("core/http_client_mtls.zig");
    _ = @import("providers/jwks.zig");
    _ = @import("providers/google.zig");
    _ = @import("internal/env.zig");
    _ = @import("testing.zig");
    _ = @import("doc_check.zig");
    _ = @import("testing/http.zig");
    _ = @import("testing/port.zig");
    _ = @import("core/listen_port.zig");
    _ = @import("middlewares/https.zig");
    _ = @import("modules/mail/mail.zig");
    _ = @import("modules/mail/message.zig");
    _ = @import("modules/mail/http.zig");
    _ = @import("modules/mail/brevo.zig");
    _ = @import("modules/mail/resend.zig");
    _ = @import("modules/mail/postmark.zig");
    _ = @import("modules/mail/memory.zig");
    _ = @import("modules/mail/log.zig");
}

test "every file with tests is part of the unit test binary" {
    try @import("testing.zig").expectAllTestsDiscovered(@import("test_manifest"));
}
