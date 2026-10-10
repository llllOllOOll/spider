# <img src="assets/spider_logo.png" width="32" height="32" alt="Spider Logo"> Spider v0.10.1

Build web servers in Zig — performant, productive, and batteries-included.

**Batteries included:** PostgreSQL, SQLite, JWT auth, Keycloak/JWKS, Clerk,
Google OAuth, role and policy based access control, WebSockets, SSE, Web Push,
Cloudflare R2, multipart upload, htmx helpers, a template engine, and a CLI that
scaffolds apps and checks them.

📖 **Documentation:** this README, and [`llms.txt`](llms.txt) — the maintained API reference  
🔧 **CLI:** `spider new myapp`

> **Spider runs on the official Zig 0.17.0 release** (since Spider 0.8.0). No development
> build, no patched compiler: download Zig 0.17.0 from
> [ziglang.org/download](https://ziglang.org/download/) and build. From now
> on Spider only targets official Zig releases; the next move is to 0.18.0,
> when it ships. See [Zig Version Policy](#zig-version-policy).

---

## Installation

### Quick Install (Recommended)

Installs the `spider` CLI (to `~/.local/bin`, or `--install-dir PATH`):

```bash
curl -fsSL https://spiderme.org/install.sh | bash
```

Or a specific version:

```bash
curl -fsSL https://spiderme.org/install.sh | bash -s -- --version v0.10.1
```

Then `spider new myapp` creates a project with Spider already added as a
dependency and its `build.zig` wired (see [Quick Start](#quick-start)).

### Manual Install

Add Spider as a dependency in your `build.zig.zon`:

```bash
zig fetch --save git+https://github.com/llllOllOOll/spider#main
```

Then in your `build.zig`:

```zig
const spider_dep = b.dependency("spider", .{
    .target = target,
    .optimize = optimize,
    // I/O backend: comment one line and uncomment the other.
    .io_backend = .threaded, // OS threads, blocking sockets (default)
    // .io_backend = .zio, // fibers on an event loop (epoll)
    // .pg = true, .sqlite = true, .r2 = true, .qrcode = true, .xlsx = true,
});
const spider_mod = spider_dep.module("spider");

// spider.config.zig is read only when it is registered on the spider module.
spider_mod.addImport("spider_config", b.createModule(.{
    .root_source_file = b.path("spider.config.zig"),
    .imports = &.{.{ .name = "spider", .module = spider_mod }},
}));

const exe = b.addExecutable(.{
    .name = "myapp",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "spider", .module = spider_mod }},
    }),
});

// Optional: embed the templates in the binary (then, in main.zig:
// `pub const spider_templates = @import("embedded_templates.zig").EmbeddedTemplates;`).
const gen = b.addRunArtifact(spider_dep.artifact("generate-templates"));
gen.addArg("src/");
gen.addArg("src/embedded_templates.zig");
exe.step.dependOn(&gen.step);
```

Easiest: `spider new myapp` generates all of this.

---

## Requirements

Zig **0.17.0**, the official release, unmodified:

```bash
zig version
# 0.17.0
```

Download it from [ziglang.org/download](https://ziglang.org/download/).
`minimum_zig_version` in `build.zig.zon` declares the same version (Spider
and generated apps). In GitHub Actions,
[`mlugg/setup-zig`](https://codeberg.org/mlugg/setup-zig) installs it
(`with: version: 0.17.0`).

---


---

## Quick Start

```bash
spider new myapp          # HTML views + SQLite; --pg, --no-db, --api, --pwa, --ui=tailwind
cd myapp
spider dev                # http://localhost:3000, rebuilt and reloaded as you edit
spider g feature posts    # a CRUD feature in src/features/posts/ + a migration
```

A minimal app by hand:

```zig
const std = @import("std");
const spider = @import("spider");

pub fn main() !void {
    var server = spider.app(.{});
    defer server.deinit();

    try server
        .get("/", home, .{})
        .get("/users/:id", user, .{})
        .post("/users", createUser, .{})
        .listen(.{ .port = 3000 });
}

fn home(c: *spider.Ctx) !spider.Response {
    return c.json(.{ .message = "Hello from Spider!" }, .{});
}

fn user(c: *spider.Ctx) !spider.Response {
    const id = c.params.get("id") orelse return error.NotFound;
    return c.json(.{ .user_id = id }, .{});
}

fn createUser(c: *spider.Ctx) !spider.Response {
    const Input = struct { name: []const u8, email: []const u8 };
    const in = try c.bodyJson(Input);
    return c.json(.{ .created = true, .name = in.name }, .{ .status = .created });
}
```

```
info: Server listening on http://127.0.0.1:3000
```

The third argument of every route is its config (`.{}` for none, see
[Routing](#routing)). `listen(.{ .port, .host })` fields you leave out come from
`spider.config.zig` (see [Configuration](#configuration)), else `127.0.0.1:3000`.
`spider.app()` also registers `GET /up` and `GET /_spider/health`.

### `spider dev`

```bash
spider dev            # or: spider dev --port 4000
```

One command, left running. It builds the app, runs it, and after every
save rebuilds it, replaces the running process and reloads the browser.

- **Fast where Zig allows it.** It runs `zig build dev --watch` with
  incremental compilation on x86_64 Linux: in a generated app an edit is on
  the page in about half a second. Elsewhere it is a normal build each
  time.
- **A build that fails changes nothing.** The app that is up keeps serving,
  the compiler's errors are in the terminal, and the page does not reload
  until a build succeeds.
- **The browser reloads by itself.** A Debug build started by `spider dev`
  adds a small script to its HTML pages. It is served by the app itself
  (`/_spider/dev.js`, WebSocket `/_spider/dev`, before any middleware), so
  it works behind your auth and under a strict Content-Security-Policy.
  None of it exists in a release build.
- **Template and stylesheet edits** do not restart the app. Templates are
  read from disk in a Debug build (see
  [Embedded and runtime modes](#embedded-and-runtime-modes)), so the browser
  just reloads. A new, removed or renamed template file restarts the app.
- `--port N` makes the app listen on N instead of the port in its code.
- Ctrl+C stops everything. One `spider dev` per project. Not on Windows
  yet.

Apps created by `spider new` are ready for it. An older app needs the `dev`
build step; `spider dev` prints the lines to add to `build.zig` when it is
missing:

```zig
const spider_build = @import("spider");
const dev = spider_build.devStep(b, spider_dep.artifact("spider-dev-notify"), exe, .{
    .assets = &.{"public/css/app.css"}, // what the page loads besides the binary
    .templates = "src",                 // where the templates are
});
dev.step.dependOn(&css.step); // the Tailwind step
spider_build.watchSources(b, css, "src", &.{ ".css", ".html", ".js" });
```

`zig build run` still works: one build, one run, no reload.

### A generated app

```
myapp/
├── build.zig / build.zig.zon / spider.config.zig
├── .env (git-ignored) / .env.example / Dockerfile / docker-compose.yml / AGENTS.md
├── public/                 — favicon, images, js/, css/app.css (built by tailwindcss)
├── bin/                    — tailwindcss, icon plugins (spider install)
└── src/
    ├── main.zig            — server.use(spider.logger).mountFeatures(features).onError(...).listen(...)
    ├── styles.css / ui.css — Tailwind entry; ui-* classes of the chosen UI kit
    ├── core/               — db/migrations/*.sql
    ├── shared/templates/   — layout.html, app.html, nav/side bars, toast
    └── features/
        ├── mod.zig         — lists the features
        └── home/           — mod.zig, controller.zig, routes.zig, routes_test.zig, views/
```

Each feature exposes `routes.build()` (and any other zero-argument function
returning a `spider.Group`), optionally `pub const jobs = .{spider.every(ms, fn)}`
and `pub fn boot(b: spider.Boot) !void`. `server.mountFeatures(features)` mounts
them all; `spider routes` prints the result.

---

## Routing

```zig
_ = server
    .get("/", home, .{ .public = true })
    .post("/users", createUser, .{ .roles = &.{"admin"} })
    .get("/users/:id", getUser, .{ .authenticated = true })
    .put("/users/:id", updateUser, .{ .roles = &.{"admin"} })
    .delete("/users/:id", deleteUser, .{ .roles = &.{"admin"} })
    .patch("/users/:id", patchUser, .{ .roles = &.{"admin"} })
    .head("/users/:id", headUser, .{});
```

Every builder method returns `*Server`: chain calls, or write `_ = server.x(...);`
as a statement. Paths: `/users/:id` params, a trailing `/*` wildcard.

### Route config (third argument)

`.{}` or any of these (unknown keys are compile errors):

| Key | Meaning |
|-----|---------|
| `.roles = &.{"admin"}` | Any of these roles, else 403 |
| `.org_roles = &.{"admin"}` | Role in the active organization, else 403 |
| `.authenticated = true` | Any logged-in user, else 401 |
| `.public = true` | No login: auth middlewares let it through |
| `.policy = spider.policy("name", check)` | Any other rule (see [Authorization](#authorization)) |
| `.quiet_log = true` | Successful requests aren't logged (errors are) |
| `.allow_http = true` | Exempt from `spider.forceHttps` |

Handlers read them with `c.route()`. `.public` together with roles or
`.authenticated` doesn't compile.

### Groups and features

```zig
var admin = spider.Group.init("/admin");
_ = admin
    .defaults(.{ .roles = &.{"admin"} })       // before the routes; inherited
    .use(audit)                                // every route of the group, after RBAC
    .get("/users", listUsers, .{})             // GET /admin/users, admin only
    .get("/status", status, .{ .public = true, .quiet_log = true }); // replaces the defaults
_ = server.mount(admin);
```

A route that declares `.roles`/`.org_roles`/`.public`/`.authenticated`/`.policy`
replaces the group's defaults; `.quiet_log`/`.allow_http` override one by one.
`sseWith(path, handler, config)` takes the same config for SSE routes. Route
matching doesn't depend on registration order.

### Typed handler parameters

```zig
fn getPost(id: spider.Path(i64, "id"), c: *spider.Ctx) !spider.Response {
    return c.json(.{ .id = id.value }, .{}); // "/posts/abc" → 400
}

const PostForm = struct { title: []const u8, body: []const u8 };
fn savePost(form: spider.Form(PostForm), c: *spider.Ctx) !spider.Response {
    return c.json(.{ .title = form.value.title }, .{});
}
```

`spider.Loaded(T)` receives the record a `resourcePolicy` loaded (see
[Authorization](#authorization)).

---

## Context — `c: *spider.Ctx`

### Responses

```zig
return c.json(.{ .name = "Alice" }, .{});
return c.json(.{ .@"error" = "not found" }, .{ .status = .not_found });
return c.text("Hello", .{});
return c.html("<h1>Hello</h1>", .{});
return c.view("users/index", .{ .users = users }, .{});          // a view by name
return c.viewFragment("users/index", "UserRow", data, .{});     // one component (htmx partial)
return c.render("<p>{ name }</p>", .{ .name = "Ana" }, .{});    // a template string
return c.redirect("/login");
return c.download(bytes, .{ .filename = "relatório.csv", .content_type = spider.content_types.csv }); // a file
return error.NotFound;                                           // → 404 (onError / default mapping)
```

`ResponseOptions`: `.status`, `.headers = &.{.{ "X-Custom", "v" }}`, `.cookies`.
Errors map to statuses by default: `NotFound` 404, `Unauthorized` 401,
`Forbidden` 403, `BadRequest` 400, …; `c.setErrorDetail(msg)` adds a message.

### Reading requests

```zig
const id = c.params.get("id");            // path param (or a spider.Path parameter)
const page = c.query("page");             // query string value (not percent-decoded)
const q = c.queryDecoded("q");            // decoded once like a form field: "Jo%C3%A3o+Silva" → "João Silva"
const auth = c.header("Authorization");
const token = c.cookie("session");
const input = try c.bodyJson(Input);      // JSON body
const form = try c.parseForm(Input);      // application/x-www-form-urlencoded
const ip = c.clientIp();                  // client IP (see Security)
const rid = c.requestId();                // X-Request-Id
```

### Arena allocator

`c.arena` is per request and reset after it — allocate freely, don't free.

### htmx

```zig
if (c.isHtmx()) return c.viewFragment("posts/index", "PostList", data, .{});
switch (c.requestKind()) { .fragment => {}, .boosted => {}, .full => {} } // htmx 2 and 4

// Response headers, typed:
return c.view("posts/_form", data, .{
    .status = .unprocessable_entity,
    .headers = try c.htmx(.{
        .retarget = "#form",
        .reswap = .outerHTML,
        .trigger = try c.hxEvent("spider:toast", .{ .message = "Check the form", .type = "warning" }),
    }),
});
```

`c.htmx` also takes `.trigger_after_swap`, `.trigger_after_settle`, `.reselect`,
`.push_url`, `.replace_url`, `.redirect`, `.location`, `.refresh`.
`server.use(spider.varyHtmx)` adds `Vary: HX-Request` to HTML responses.

### Cookies

```zig
// Set-Cookie string (defaults: HttpOnly, Secure, SameSite=Lax, Path=/)
const cookie = try c.setCookie("session", token, .{ .max_age = 3600 });
return c.redirect("/"); // or put it in .headers = &.{.{ "Set-Cookie", cookie }}

// Or as ResponseOptions
const opts = try c.withCookie("theme", "dark", .{ .http_only = false });
return c.json(.{ .ok = true }, opts);

// Remove (same path/domain it was set with)
const gone = try c.deleteCookie("session", .{});
```

`CookieOptions`: `.http_only`, `.secure`, `.same_site`, `.path`, `.max_age`,
`.domain` (default host-only). `;`, CR/LF or control characters in a name, value
or attribute are `error.InvalidCookie`.

### Identity

Auth providers fill the identity from the token. When users or roles live in
your database, set them from a middleware registered after the auth one:

```zig
fn loadRoles(c: *spider.Ctx, next: spider.NextFn) anyerror!spider.Response {
    if (c.userId()) |id| {
        for (try rolesOf(c.arena, id)) |r| try c.addRole(r); // or c.setRoles(list)
        // try c.addOrgRole(.{ .org_id = "7", .role = "admin" });
    }
    return next(c);
}
```

Also `c.setUser(.{ .id, .email, .name })` (apps with their own login),
`c.roles()`, `c.hasRole(r)`, `c.activeOrgId()`, `c.setActiveOrg(id)`.
`.authenticated`, `.roles`, `.org_roles` and policies read this, whatever the source.

---

## Middleware

```zig
_ = server.use(loggerMiddleware);              // every request
_ = server.useAt("/api/*", apiMiddleware);     // a path prefix
_ = server.mount(group);                       // Group.use(mw): a group's routes
_ = server.onError(spider.errorHandler(.{}));  // or your own fn(*Ctx, anyerror) !Response
```

### Writing middleware

```zig
fn requireLogin(c: *spider.Ctx, next: spider.NextFn) anyerror!spider.Response {
    const token = c.cookie("token") orelse return c.redirect("/login");
    _ = spider.auth.jwtVerify(spider.auth.Claims, c.arena, c._io, token, secret) catch
        return c.redirect("/login");
    return next(c);
}
```

### Ready-made

```zig
_ = server
    .use(spider.logger)
    // .use(spider.loggerWith(.{ .quiet_paths = &.{"/keepalive"} }))
    .use(spider.forceHttps(.{ .default_base_url = "https://example.com" }))
    .use(spider.varyHtmx)
    .use(spider.gzip)
    .onError(spider.errorHandler(.{ .unauthorized_redirect = "/login", .template_not_found_is_404 = true }));
```

- `spider.logger`: `2026-09-26T17:36:33.178Z [200] GET /users 12.0ms rid=… user=- org=-`.
- `spider.errorHandler`: JSON `{error, request_id}` for JSON clients, an htmx
  toast (`HX-Trigger`) for htmx requests, a page otherwise.
- `spider.forceHttps`: redirects when `X-Forwarded-Proto: http`; honors `.allow_http`.

---

## Authorization

Route config declares who may call each route:

```zig
_ = server
    .get("/admin", admin, .{ .roles = &.{"admin"} })
    .get("/org", org, .{ .org_roles = &.{"manager"} })
    .get("/me", me, .{ .authenticated = true })
    .get("/beta", beta, .{ .policy = spider.policy("beta_tester", isBetaTester) });

fn isBetaTester(c: *spider.Ctx) bool { // or !bool
    return c.hasRole("beta");
}
```

A policy that says no gives 403, or 401 when nobody is logged in.

### Rules about a record: `resourcePolicy`

```zig
.post("/posts/:id/edit", edit, .{ .policy = spider.resourcePolicy("post_owner", Post, .{
    .load = loadPost,     // fn (*Ctx) ?Post | !?Post | !Post — missing → 404
    .check = isOwner,     // fn (*Ctx, *const Post) bool | !bool — false → 403
    .deny = .not_found,   // optional: 404 instead of 403 (ids can't be probed)
}) })

fn edit(post: spider.Loaded(Post), c: *spider.Ctx) !spider.Response { // or c.loaded(Post)
    return c.json(.{ .title = post.value.title }, .{});
}
```

Anonymous requests get 401 before anything is loaded; the record reaches the
handler loaded once. Scope the loader to the tenant (e.g. `WHERE id = $1 AND
org_id = $2`) and a record of another tenant is simply "not found".

### All rules of a model: `policySet`

```zig
pub const Tickets = spider.policySet(Ticket, .{
    .name = "ticket",
    .load = loadTicket,
    .deny = .not_found,
    .rules = .{
        .view = canView,
        .update = isOwner,
        .delete = .{ .check = isAdmin, .deny = .forbidden },
    },
});

// routes:   .{ .policy = Tickets.route(.update) }
// handlers: const can_edit = try Tickets.can(c, .update, ticket);
```

An action missing from `.rules` doesn't compile.

### Keeping access reviewed

- `spider routes` prints method, path, access (`public`, `authenticated`,
  `roles:…`, `org:…`, `policy:…`, or `-`) and flags.
- `spider routes --lock` writes `routes.lock` (commit it); `spider routes --diff`
  exits 1 when a route or its access changed; `--check` fails when the app has
  auth and a route declares no access.
- `spider.testing.expectRoutes(routes.build(), &.{ .{ "GET", "/posts", "roles:editor" }, ... })`
  pins a feature's table in a test.
- `server.requireRouteAccess()` (or `.require_route_access = true`): `listen()`
  refuses routes that declare no access.

---

## Authentication

### Keycloak (recommended)

`spider generate auth` adds the whole flow. By hand:

```zig
var kc = try spider.keycloak.Keycloak.init(allocator, io, spider.keycloak.KeycloakConfig.fromEnv());
defer kc.deinit();

_ = server
    .use(kc.middleware())
    .get("/auth/login", kc.loginHandler(), .{ .public = true })
    .get("/auth/callback", kc.callbackHandler(), .{ .public = true })
    .get("/auth/refresh", kc.refreshHandler(), .{ .public = true });
```

`fromEnv()` reads `KEYCLOAK_BASE_URL`, `KEYCLOAK_REALM`, `KEYCLOAK_CLIENT_ID`,
`KEYCLOAK_CLIENT_SECRET`, `KEYCLOAK_REDIRECT_URI`. Tokens must be issued to this
client (`.audience`, default `client_id`). `loginHandler`/`authorize()` set and
check the OAuth `state`. An expired token redirects to `refresh_path`; htmx and
SSE requests get 401 instead. Google login: add Google as an identity provider
in Keycloak.

### Any OIDC provider (JWKS)

```zig
var jwks_auth = try spider.jwks.JwksAuth.init(allocator, io, .{
    .jwks_url = "https://example.com/.well-known/jwks.json",
    .issuer = "https://example.com/",
    .audience = "my-api",                          // reject tokens for other clients
    .roles_claim = "https://myapp.example/roles",  // Auth0; "cognito:groups", "roles", ...
    .org_claims = .none,
    .api_mode = true,                              // 401 JSON instead of redirects
});
defer jwks_auth.deinit();
_ = server.useAt("/api/*", jwks_auth.middleware());
```

Where the token carries roles and organizations (also on `KeycloakConfig`):

- `.roles_claim`: a claim name or a dotted path (default Keycloak's
  `"realm_access.roles"`; `"resource_access.<client>.roles"` for client roles).
- `.org_claims`: `.phase_two` (default, Keycloak Phase Two organizations),
  `.clerk`, `.none`.
- `.map_claims = fn (c: *spider.Ctx, claims: std.json.ObjectMap) !void`: map
  anything else with `c.addRole` / `c.addOrgRole` / `c.setActiveOrg`.

### Clerk

```zig
var clerk_auth: spider.clerk.Clerk = undefined; // file scope

pub fn main(init: std.process.Init) !void {
    clerk_auth = try spider.clerk.Clerk.init(init.gpa, init.io, .{
        .publishable_key = spider.env.getOr("CLERK_PUBLISHABLE_KEY", ""),
        .secret_key = spider.env.getOr("CLERK_SECRET_KEY", ""),
        // .roles_claim = "roles", // Clerk has no roles claim by default
    });
    defer clerk_auth.deinit();

    var server = spider.app(.{});
    defer server.deinit();
    try server
        .use(clerk_auth.middleware())
        .get("/login", clerkLogin, .{ .public = true })
        .get("/auth/callback", clerk_auth.callbackHandler(), .{ .public = true })
        .listen(.{});
}

fn clerkLogin(c: *spider.Ctx) !spider.Response {
    return c.redirect(try clerk_auth.authUrl(c.arena));
}
```

The active organization's role (Clerk `o.rol` / `org_role`) feeds `.org_roles`.

### HS256 JWT (your own login)

```zig
const secret = spider.env.getOr("JWT_SECRET", "");
const token = try spider.auth.jwtSign(c.arena, .{
    .sub = 42, .email = "a@b.c", .name = "Ana", .exp = now + 3600, // spider.auth.Claims
}, secret);
const claims = try spider.auth.jwtVerify(spider.auth.Claims, c.arena, c._io, token, secret);
```

`spider.auth.Auth.init(.{ .secret = secret }).asFn()` is a middleware that
verifies the `token` cookie, skips `.public` routes and sets the user id
(`c.userId()`).

### Google

`spider.google.authUrl(arena, cfg)` and `spider.google.fetchProfile(c, code, cfg)`
give you the Google profile. They don't send or verify an OAuth `state`: for
production, prefer Keycloak with Google as identity provider.

---

## Security defaults

| Config | Default | What it does |
|--------|---------|--------------|
| `origin_check` | on | A cross-site POST/PUT/PATCH/DELETE or WebSocket upgrade from a browser gets 403 before routing (`Sec-Fetch-Site` same-origin/none pass; else `Origin` must match `Host` or be trusted). Requests without those headers (webhooks, servers) pass. `.trusted_origins`, `.exempt_paths` (e.g. a form_post callback), `.enabled = false`. |
| `max_body_bytes` | 10 MiB | A larger `Content-Length` gets 413 before anything is read. |
| `trusted_proxies` | none | Proxies whose `X-Forwarded-For` `c.clientIp()` believes (`&.{"10.0.0.0/8"}`); without them the header is ignored. |

Static files are served before routing and middleware: they are always public.

---

## Templates

Spider's engine: variables, conditions, loops, layout inheritance (`extends`),
components (PascalCase files), named layout slots and Markdown views. `{ … }` is
HTML-escaped.

### Syntax

```html
<h1>{ title }</h1>
<p>{ user.name } — { user.address.city }</p>
<p>{ bio ?? "No bio yet" }</p>

if (user.is_admin) {
  <span class="badge">Admin</span>
} else if (user.role == "editor") {
  <span>Editor</span>
} else {
  <span>Member</span>
}

for (users) |user| {
  <li>{ loop.index }: { user.name }</li>
}

if (users.len > 0) {
  <p>Users found</p>
}
```

- Conditions: `==`/`!=` against a literal, `<`, `<=`, `>`, `>=`, `and`, `or`, `!x`,
  `list.len` (`.len` works in conditions only; pass counts as data).
- `??` applies when the value is missing, empty or `false`.
- `{{ … }}` outputs a literal `{ … }` (Alpine `x-data`); `<script>`/`<style>`
  bodies are never interpolated.
- Data: a struct literal — strings, ints, floats, bools, optionals, nested
  structs, slices of structs. `spider.RawHtml{ .html = s }` is inserted verbatim.

### Boolean attributes and conditional classes

```html
<input name="q" { disabled if (locked) } { required if (need) }>
<a class="ui-btn { "ui-btn-active" if (tab == "home") }">Home</a>
```

The word or string is printed only when the condition holds. Don't write
`disabled="{ locked }"`: the attribute is present — so on — even when the value
is `false`; `spider check` flags it (`bool-attr`).

### Components

```html
<!-- views/components/UserInfo.html -->
<div class="user">
  <strong>{ name }</strong> — { role }
  { slot }
</div>

<!-- a view -->
<UserInfo name="{ user.name }" role="admin">
  <p>Extra content goes to { slot }.</p>
</UserInfo>
```

Props are literals or `{ expressions }` (escaped). A component has one
`{ slot }`. `<SiteNav />` finds `SiteNav` or `site_nav`. Nesting is capped
(`spider.template_max_component_depth`).

### Layouts and named slots

```html
<!-- layout.html -->
<header>{ slot_header }</header>
<main>{ slot }</main>

<!-- page.html -->
extends "layout"
<p>Welcome back!</p>      <!-- goes to { slot } -->
{ slot_header }
<h1>Dashboard</h1>        <!-- goes to { slot_header } -->
```

`extends "layout"` must be the first line. Named slots are for layouts.

### Markdown views

A view whose first line is `-- doc` is rendered as Markdown and returned as is —
no `{ }` processing, no layout:

```markdown
-- doc
# API Reference
Welcome to the API docs...
```

### Template helpers

`{ asset_url("css/app.css") }` calls a `pub fn` of your `template_helpers`
module (`spider_mod.addImport("template_helpers", …)`; each is
`fn (std.mem.Allocator, []const []const u8) ![]const u8`). Arguments are string
literals; the result is inserted without escaping.

### Embedded and runtime modes

An app's templates are either read from disk on every request or embedded
in the binary. By default the build decides:

| Build | Templates | Why |
|---|---|---|
| Debug (`zig build`, `zig build run`, `spider dev`) | read from `views_dir` | an edit shows on the next request: no rebuild, no restart |
| Release (`-Doptimize=ReleaseSafe`/`Fast`/`Small`, what the generated Dockerfile runs) | embedded in the binary | the binary is all a deploy needs |

A Debug binary therefore needs the template directory beside it (it says so
when it starts, and warns if the directory is missing). To choose yourself,
set `templates` on the dependency in `build.zig`:

```zig
const spider_dep = b.dependency("spider", .{
    .target = target,
    .optimize = optimize,          // the rule above follows this
    .templates = .embedded,        // or .disk, or .auto (the default)
});
```

- **Embedded** needs what a `spider new` project has: the build runs
  `generate-templates`, writing `src/embedded_templates.zig`, and `main.zig`
  declares
  `pub const spider_templates = @import("embedded_templates.zig").EmbeddedTemplates;`.
- **From disk** (runtime): views are read from `views_dir`
  (`spider.config.zig`; default `"./views"`, `null` → `"src"`). An app that
  does not declare `spider_templates` is always in this mode.

View names come from paths:

| File | Name | Use |
|------|------|-----|
| `features/home/views/index.html` | `home_index` | `c.view("home/index", ...)` |
| `features/users/views/users.html` | `users` | `c.view("users", ...)` |
| `views/components/UserInfo.html` | `components_UserInfo` (+ `UserInfo`) | `<UserInfo />` |

---

## Database

### PostgreSQL (pure Zig)

Needs `.pg = true` on the spider dependency. A connection pool (default 5),
retry on connection failures (5 attempts, 1s→8s backoff; auth errors fail at once).

> Thanks to [karlseguin](https://github.com/karlseguin) for [pg.zig](https://github.com/karlseguin/pg.zig), the base of Spider's PostgreSQL driver (we use a customized fork).

```zig
const db = spider.pg;

pub fn main(init: std.process.Init) !void {
    try db.init(init.arena.allocator(), init.io, .{}); // unset fields: PG_* env / .env
    defer db.deinit();

    var server = spider.app(.{});
    defer server.deinit();
    try server.get("/users", listUsers, .{}).listen(.{ .port = 3000 });
}
```

| Field | Env | Default |
|-------|-----|---------|
| `.host` | `PG_HOST` | `localhost` |
| `.port` | `PG_PORT` | `5432` |
| `.user` | `PG_USER` | `postgres` |
| `.password` | `PG_PASSWORD` | `postgres` |
| `.database` | `PG_DB` | `postgres` |
| `.pool_size` | — | `5` |
| `.mapping` | — | `.fail` (missing column / NULL into a non-optional field → error; `.warn` logs once) |

#### Queries

```zig
const User = struct { id: i32, name: []const u8, email: ?[]const u8 };

fn listUsers(c: *spider.Ctx) !spider.Response {
    const users = try db.query(User, c.arena, "SELECT id, name, email FROM users", .{});
    return c.json(users, .{});
}

fn getUser(c: *spider.Ctx) !spider.Response {
    const id = c.params.get("id") orelse return error.NotFound;
    const user = try db.queryOne(User, c.arena, "SELECT id, name, email FROM users WHERE id = $1", .{id})
        orelse return error.NotFound;
    return c.json(user, .{});
}
```

`db.query(T, arena, sql, params)` returns `[]T` for structs (fields matched by
column name; `?T` for nullable columns), `i32`/`i64` for a single scalar, `void`
for statements. `queryOne` returns `?T`. Params `$1..$n` are bound, never
interpolated. `queryExecute(T, arena, sql)` runs SQL without params (with `void`,
several `;`-separated statements on one connection).

#### Transactions

```zig
var tx = try db.begin();
defer tx.rollback(); // no-op after commit
_ = try tx.query(void, c.arena, "INSERT INTO accounts (name) VALUES ($1)", .{"Ana"});
try tx.commit();
```

Or `db.transaction(R, context, body)`: commit on return, rollback on error. Each
`db.*` call uses its own pooled connection, so `BEGIN` through `db.query` is
refused (`error.UseBeginForTransactions`).

#### Errors

```zig
db.query(void, c.arena, "INSERT INTO users (email) VALUES ($1)", .{email}) catch |err| switch (err) {
    error.UniqueViolation => return c.json(.{ .@"error" = "email taken" }, .{ .status = .conflict }),
    else => return err,
};
```

Unhandled database errors map to 409 (unique/foreign key), 400 (bad input,
NOT NULL/CHECK), 422 (`RAISE`) and 503 (deadlock, serialization, lock timeout).
`exec`, `execRaw`, `queryWith`, `queryRow`, `queryAs`… are deprecated: use
`query`/`queryOne`/`queryExecute`.

### SQLite

Needs `.sqlite = true` on the spider dependency (bundled sqlite3, links libc):

```zig
try spider.sqlite.init(allocator, io, .{ .path = "app.db" }); // null → SQLITE_PATH env, else "db.sqlite"
defer spider.sqlite.deinit();
```

Same `query`/`queryOne`/`queryExecute`/`begin()` API; the scalar type is `i64`.

---

## Server-Sent Events (SSE)

```zig
fn events(sse: *spider.Sse) !void {
    try sse.joinWithReplay("notifications"); // resend what was missed (Last-Event-ID)
    try sse.send("hello", .{ .time = "now" });
    sse.wait(); // until the client disconnects; hub events reach it meanwhile
}

_ = server
    .sseWith("/events", events, .{ .authenticated = true })
    .sseHeartbeat(null); // ": heartbeat" every 30 s
```

| Method | Description |
|--------|-------------|
| `s.send(event, data)` | Send JSON |
| `s.sendHtml(event, html)` | Send HTML as is (htmx `sse-swap`) |
| `s.join(channel)` / `s.joinWithReplay(channel)` | Join a channel (replaces previous) |
| `s.subscribe(channel)` / `s.subscribeWithReplay(channels)` | Add channels |
| `s.joinUser(id)` | Receive `hub.notifyUser(id, …)` |
| `s.setRetry(ms)` | Client reconnect delay |
| `s.param` / `s.header` / `s.cookie` / `s.lastEventId()` | Request data |
| `s.wait()` | Block until the client disconnects |

From any handler or job, through the hub:

```zig
const hub = c.sseHub(); // needs at least one sse route
hub.emitTo("notifications", "new_post", .{ .id = 42 });      // JSON, recorded for replay
hub.emitHtmlTo("notifications", "badge", "<span>3</span>");  // HTML for sse-swap, recorded
hub.notifyUser(42, "private_msg", .{ .text = "Hi" });
hub.broadcast("plain message");
```

Multi-line data goes out as one `data:` line per line. `emitHtmlTo` renders once
for everyone on the channel: keep per-user data out of it. Periodic work:
`server.sseInterval(ms, fn (*spider.Hub) void)`, or `pub const jobs =
.{spider.every(ms, fn)}` in a feature.

---

## WebSocket

```zig
fn chat(ws: *spider.Ws) !void {
    try ws.join("room:1");
    while (try ws.next()) |msg| {
        ws.broadcastTo("room:1", msg.data);
    }
}

_ = server.ws("/ws/chat", chat);
```

| Method | Description |
|--------|-------------|
| `w.next()` | Next message (`.data`, `.type`), null when closed |
| `w.send(text)` | Send to this connection |
| `w.join(channel)` / `w.joinUser(id)` | Join a channel / a user's channel |
| `w.broadcast(text)` / `w.broadcastTo(channel, text)` | Send to all / a channel (`…Fmt` variants too) |
| `w.param(key)` | Path parameter |

`server.wsInterval(path, ms, fn (*spider.Hub) void)` calls the function with that
endpoint's hub every `ms`. Cross-site upgrades are refused (`origin_check`).
`ws()` takes no route config: global and `useAt` middleware still apply.

---

## Web Push

```zig
var wp = spider.push.WebPush.initFromEnv(); // VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY
try wp.send(c, subscription, payload_json, 3600);
```

`spider generate-vapid mailto:admin@example.com` prints the keys. Outside a
handler (jobs): `wp.sendRaw(arena, io, sub, payload, ttl)`. A 410 answer is
`error.PushSubscriptionExpired`: delete that subscription.

---

## Mail

A client of mail providers' HTTP APIs (not a mail server: it does not deliver
to inboxes itself and does not receive mail).

```zig
var mailer = try spider.mail.Mailer.fromEnv(); // once, at startup

_ = try mailer.send(c, .{
    .to = &.{.{ .name = "Ada", .address = "ada@example.com" }},
    .subject = "Welcome",
    .html = "<h1>Welcome!</h1>",
    .text = "Welcome!",
});
```

`fromEnv()` reads `MAIL_TRANSPORT` (`brevo`, `resend`, `postmark` or `log`,
the default), `MAIL_FROM` (`App <no-reply@example.com>`, the sender of a mail
that sets no `.from`), the transport's key (`BREVO_API_KEY`, `RESEND_API_KEY`
or `POSTMARK_SERVER_TOKEN`) and optionally `MAIL_BASE_URL`. The `log`
transport delivers nothing and writes the message to the log (development).
Without the environment: `spider.mail.Mailer{ .backend = .{ .brevo = .{ .api_key = key } }, .from = .{ .address = "no-reply@example.com" } }`.

A mail also takes `.from`, `.cc`, `.bcc` and `.reply_to`. `send` returns a
`Receipt` (`.message_id`, null when the provider gave none): the provider
accepted the message, which is not inbox delivery. Outside a handler (jobs):
`mailer.sendWith(arena, io, mail)`.

Errors: `MailMissingFrom`, `MailMissingRecipients`, `MailMissingBody`,
`MailInvalidAddress`, `MailInvalidHeader` (nothing was sent);
`MailUnauthorized` (API key refused), `MailRejected` (the provider refused
this message), `MailDeliveryFailed` (network, rate limit or provider failure:
worth retrying). `send` waits for the provider's answer and has no timeout
and no retry of its own.

In tests, the memory backend keeps the messages instead of sending them:

```zig
var outbox: spider.mail.Outbox = .init(std.testing.allocator);
defer outbox.deinit();
const mailer: spider.mail.Mailer = .{ .backend = .{ .memory = &outbox } };
// ... run the code that sends ...
try std.testing.expectEqualStrings("Welcome", outbox.last().?.subject);
```

Another provider: `.backend = .{ .custom = .{ .ptr = &state, .sendFn = mySend } }`
with `fn mySend(ptr: *anyopaque, arena: std.mem.Allocator, io: std.Io, mail: spider.mail.Mail) anyerror!spider.mail.Receipt`
(the mail is already validated, with `.from` set). The Resend transport sends
recipients as bare addresses (their display names are dropped).

---

## Cloudflare R2

Needs `.r2 = true` on the spider dependency:

```zig
var r2 = try spider.r2.R2.initFromEnv(io); // or spider.r2.R2.init(io, .{ ... })
defer r2.deinit();

try r2.put(c, "folder/file.txt", body, "text/plain");
const data = try r2.get(c, "folder/file.txt");
const exists = try r2.head(c, "folder/file.txt");
try r2.delete(c, "folder/file.txt");
const upload_url = try r2.presignedPut(c.arena, "uploads/a.png", "image/png", 600);
const public_url = try r2.publicUrl(c.arena, "folder/file.txt");
```

For large uploads, let the browser `PUT` to a presigned URL instead of going
through the app.

### File downloads

```zig
fn exportCsv(c: *spider.Ctx) !spider.Response {
    const csv = try buildCsv(c.arena); // any bytes
    return c.download(csv, .{
        .filename = "Relatório de março.csv", // may come from user data
        .content_type = spider.content_types.csv,
    });
}
```

(`buildCsv` stands for your own code: this snippet is an illustration and is
not one of the examples compiled against Spider. The `exportPoll` example
below is.)

`c.download(bytes, opts)` answers with `Content-Disposition: attachment`, the
content type and `X-Content-Type-Options: nosniff`.

- **The file name can be anything**, including text a user typed: only the
  last part of a path is kept, control characters, line breaks and quotes
  are removed, it is cut to 120 bytes, and an empty result becomes
  `download`. Accents and emoji are sent the way browsers expect
  (`filename*=UTF-8''…`), with an ASCII version for old clients.
- **Options**: `.filename`, `.content_type` (default
  `spider.content_types.binary`; also `.xlsx`, `.csv`, `.pdf`, or any
  `type/subtype` string), `.disposition = .@"inline"` to show the file in
  the browser instead of saving it, `.status`, `.headers`, `.cookies`.
- **The bytes are not copied**: they must live until the response is sent.
  Memory from `c.arena` does.
- A content type with a line break is `error.InvalidContentType`.

With `spider.xlsx` (opt-in, see `modules/xlsx/README.md`):

```zig
fn exportPoll(c: *spider.Ctx) !spider.Response {
    const wb = try spider.xlsx.Workbook.init(c.arena);
    defer wb.deinit();
    const sheet = try wb.addSheet("Resultado");
    try sheet.setRow(0, 0, &.{ .{ .text = "Opção" }, .{ .text = "Votos" } }, .{ .bold = true });
    try sheet.setRow(1, 0, &.{ .{ .text = "Sim" }, .int(12) }, .{});
    return c.download(try wb.toOwnedSlice(c.arena), .{
        .filename = "resultado.xlsx",
        .content_type = spider.content_types.xlsx,
    });
}
```

---

## Multipart uploads

```zig
fn upload(c: *spider.Ctx) !spider.Response {
    var mp = try c.parseMultipart();
    defer mp.deinit();
    const title = mp.getValue("title") orelse "";
    const files = mp.getFile("photo") orelse return error.BadRequest;
    return c.json(.{ .title = title, .size = files[0].data.len }, .{});
}
```

Bodies over `max_body_bytes` (10 MiB by default) get 413.

---

## HTTP client

```zig
const http = spider.http_client;
// in a handler: io = c._io (the server's Io, required on the zio backend), arena = c.arena

var res = try http.get(io, arena, "https://api.example.com/users", .{});
defer res.deinit();
const users = try res.json([]User);
defer users.deinit();

const payload = try std.json.Stringify.valueAlloc(arena, .{ .name = "Alice" }, .{});
var created = try http.post(io, arena, "https://api.example.com/users", .{ .body = .{ .json = payload } });
defer created.deinit();

var token = try http.post(io, arena, "https://auth.example.com/token", .{
    .body = .{ .form = &.{ .{ "grant_type", "client_credentials" } } },
});
defer token.deinit();
```

Client certificates: `spider.http_client_mtls`.

---

## Dependency injection (decorations)

```zig
const App = struct { db: *Db, mailer: *Mailer };

pub fn main(init: std.process.Init) !void {
    var db: Db = .{};
    var mailer: Mailer = .{};
    var server = spider.app(App{ .db = &db, .mailer = &mailer });
    defer server.deinit();
    try server.get("/", home, .{}).listen(.{ .port = 3000 });
    _ = init;
}

fn home(c: *spider.Ctx, db: *Db) !spider.Response { // parameters matched by type
    _ = db;
    return c.text("ok", .{});
}
```

Checked at compile time. Server-level routes only (not `Group` routes), and not
mixed with `spider.Path`/`Form`/`Loaded` in the same handler.

---

## Static files

Files under `./public` are served at `/`:

```zig
_ = server.staticDir("./assets");           // replaces ./public
_ = server.staticAt("./uploads", "/media");  // or with a URL prefix (one static root)
```

Every file gets an `ETag`; a matching `If-None-Match` gets 304. URLs with
`?v=...` (e.g. from an `asset_url` helper) get `Cache-Control: public,
max-age=31536000, immutable`; others `no-cache`. Files over 10 MiB aren't
served. Static files skip routing and middleware — they are always public.

---

## Health

`GET /up` → `200 OK`, `GET /_spider/health` → `{"status":"ok","uptime_seconds":N}`
(both `.public` and `.quiet_log`, for load balancers and kamal-proxy).

There is no live reload today: rebuild and restart the app after a change.

---

## Configuration

### `spider.config.zig`

```zig
const spider = @import("spider");

pub const config = spider.Config{
    .port = 3000,
    .host = "0.0.0.0",
    .views_dir = "./src",          // runtime template mode
    .keepalive_timeout_ms = 120_000,
    .header_timeout_ms = 30_000,
    .body_timeout_ms = 60_000,
    .stream_write_timeout_ms = 10_000,
    .max_body_bytes = 10 * 1024 * 1024,
    .origin_check = .{ .trusted_origins = &.{}, .exempt_paths = &.{} },
    .trusted_proxies = &.{},       // e.g. &.{"10.0.0.0/8"}
    .require_route_access = false,
};
```

It is read by `spider.app(...)` only when the app's `build.zig` registers it as
the `spider_config` import of the spider module (`spider new` does; see
[Manual Install](#manual-install)). `spider.appWithConfig(cfg)` uses `cfg`
instead. `static_dir` (default `"./public"`, `null`: no static files) and
`workers` (accept threads of the threaded backend; `null`: one per CPU) are
config fields too.

### Environment (`.env`)

Loaded when the server is created (or on the first `spider.env.get`):

1. `.env` — base
2. `.env.<SPIDER_ENV>` — e.g. `.env.production` when `SPIDER_ENV=production` (default `development`); wins over `.env`
3. `.env.local` — local overrides; wins over the two above

A variable the process already has (the shell, the container, CI) wins over all three files: they only fill in what is missing.

```bash
PG_HOST=localhost
PG_PORT=5432
PG_USER=postgres
PG_PASSWORD=postgres
PG_DB=myapp_development
SQLITE_PATH=db.sqlite
JWT_SECRET=my-secret-key
```

```zig
const host = spider.env.getOr("PG_HOST", "localhost");
const port = spider.env.getInt(u16, "PORT", 3000); // PORT is yours: Spider doesn't read it
const debug = spider.env.getBool("DEBUG", false);
const maybe = spider.env.get("OPTIONAL_KEY");      // ?[]const u8
```

### I/O backend

Chosen at build time: `threaded` (default: OS threads, blocking sockets) or
`zio` (fibers on an event loop). In the app's `build.zig` (generated apps have
both lines, one commented):

```zig
const spider_dep = b.dependency("spider", .{
    .target = target,
    .io_backend = .threaded, // or .zio
});
```

Code that writes to sockets must use the server's Io (`c._io` in handlers).
With `zio`, handlers run on several threads: guard shared state.

---

## CLI

```bash
# New project (HTML views + SQLite by default)
spider new myapp
spider new myapp --pg                 # PostgreSQL instead of SQLite
spider new myapp --no-db              # no database
spider new myapp --api                # JSON API, no HTML views
spider new myapp --ui=tailwind        # UI kit: daisyui (default) or tailwind
spider new myapp --pwa                # installable PWA
spider new myapp --skip-downloads     # don't download tailwindcss, alpine, htmx, icons now

# Generate code (alias: spider g)
spider g feature posts [--api]        # CRUD feature + migration
spider g auth [--provider=keycloak] [--api]

spider migrate                        # apply src/core/db/migrations/*.sql

# Routes and conventions
spider routes                         # method, path, access, flags
spider routes --json | --check | --lock | --diff
spider check [--strict]               # conventions report with file:line and fix

# Frontend
spider ui                             # the UI kit; spider ui use tailwind|daisyui [--force]
spider icons                          # icon sets; spider icons add|remove heroicons|lucide|tabler
spider add pwa | spider remove pwa
spider install                        # tailwindcss, alpine, htmx, daisyUI, icon sets

spider generate-vapid mailto:admin@example.com
spider update                         # bump the spider dependency in build.zig.zon
spider self-update                    # update the CLI
spider version                        # also --version, -v
spider help <command>                 # or spider <command> --help
```

---

## Testing

```zig
// src/features/posts/routes_test.zig — pins the feature's access table
test "posts routes" {
    try spider.testing.expectRoutes(routes.build(), &.{
        .{ "GET", "/posts", "roles:editor" },
        .{ "POST", "/posts/:id/delete", "roles:admin" },
    });
}
```

Generated apps also run `spider.testing.expectConventions()` (the `spider check`
rules) and `expectAllTestsDiscovered` in `zig build test`.

---

## Spider source layout

```
src/
├── spider.zig              — public API + test discovery
├── testing.zig             — expectRoutes, expectConventions, expectAllTestsDiscovered
├── conventions.zig         — app convention rules (spider check)
├── core/                   — app.zig (Server, request lifecycle), context.zig (Ctx),
│                             handler.zig, extractors.zig, watchdog.zig, origin.zig,
│                             client_ip.zig, database.zig, http_client_mtls.zig
├── routing/                — router.zig, group.zig, route_config.zig, expect_routes.zig
├── middlewares/            — gzip, https (forceHttps), vary (varyHtmx), dbg_*
├── modules/                — auth/ (HS256), rbac, errors, static, health, push,
│                             logger, auth_marker, livereload (disabled)
├── render/                 — template engine (parser, ast, renderer, views) + zmd/
├── internal/               — config, env, logfmt, logger, url, …
├── ws/                     — websocket.zig, hub.zig, ws.zig, sse.zig
├── binding/                — form, multipart
├── providers/              — jwks, keycloak, google, clerk
└── cli/                    — the spider CLI + templates/
modules/                    — pg (pure Zig), sqlite, r2, qrcode, xlsx
```

The complete API: [`llms.txt`](llms.txt).

---

## Zig Version Policy

**Spider follows official Zig releases only.**

- Today that is **Zig 0.17.0** (see [Requirements](#requirements)): it is
  `minimum_zig_version` in `build.zig.zon`, for Spider and for generated
  apps, and what the release CI builds with.
- Spider stays on 0.17.0 until **Zig 0.18.0 is released**, and moves then.
  It does not follow Zig's development branch any more: no pinned nightly
  to hunt for on mirrors, no patched standard library.
- To use Spider you install one thing, the official Zig release from
  [ziglang.org/download](https://ziglang.org/download/).
- Other Zig versions are not supported: older ones (including 0.17.0
  development builds) are refused by `minimum_zig_version`, and master
  builds may not compile Spider.

Up to Spider 0.7.0 the project tracked development builds
(`0.17.0-dev.956` was the last one). An app on that build has to move to
Zig 0.17.0 to use Spider 0.8.0 or later; the [changelog](CHANGELOG.md) lists what to
rename.

---

## Author

Built by **Seven** (erivan cerqueira) — follow the journey on
[YouTube](https://www.youtube.com/@llllOllOOl) where Seven posts
videos about Zig and Spider development.

💬 Discord: `llll0ll00ll`

---

## License

MIT
