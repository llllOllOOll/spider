# <img src="assets/spider_logo.png" width="32" height="32" alt="Spider Logo"> Spider v0.6.9

Build web servers in Zig — performant, productive, and batteries-included.

**Batteries included:** PostgreSQL, SQLite, MySQL, JWT auth, Google OAuth,
Clerk, Keycloak, WebSockets, SSE, Web Push, Cloudflare R2, multipart upload,
HTMX support, CLI tool, and a powerful template engine.

📖 **Documentation:** this README  
🔧 **CLI:** `spider new myapp`

---

## Installation

### Quick Install (Recommended)

```bash
curl -fsSL https://spiderme.org/install.sh | bash
```

Or specify a version:

```bash
curl -fsSL https://spiderme.org/install.sh | bash -s -- --version v0.6.9
```

### Manual Install

Add Spider as a dependency in your `build.zig.zon`:

```bash
zig fetch --save git+https://github.com/llllOllOOll/spider#main
```

Then in your `build.zig`:

```zig
const spider_dep = b.dependency("spider", .{ .target = target });
const spider_mod = spider_dep.module("spider");

const exe = b.addExecutable(.{
    .name = "myapp",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "spider", .module = spider_mod },
        },
    }),
});
```

Alternatively, use the **build helper** for one-line setup:

```zig
const spider_build = @import("spider_build");
spider_build.setup(b, exe, spider_dep);
```

This automatically detects `spider.config.zig` and runs the template generator.

---

## Requirements

- Zig `0.17.0-dev` or compatible

```bash
zig version
# 0.17.0-dev.93+76174e1bc
```

---

## Quick Start

```zig
const std = @import("std");
const spider = @import("spider");

// Embed templates (optional — one line enables embed mode)
pub const spider_templates = @import("embedded_templates.zig").EmbeddedTemplates;

pub fn main() void {
    var server = spider.app(.{});
    defer server.deinit();

    server
        .get("/", homeHandler)
        .get("/users/:id", userHandler)
        .post("/users", createUserHandler)
        .listen(.{ .port = 3000 }) catch {};
}

fn homeHandler(c: *spider.Ctx) !spider.Response {
    return c.json(.{ .message = "Hello from Spider!" }, .{});
}

fn userHandler(c: *spider.Ctx) !spider.Response {
    const id = c.param("id") orelse "unknown";
    return c.json(.{ .user_id = id }, .{});
}

fn createUserHandler(c: *spider.Ctx) !spider.Response {
    const User = struct { name: []const u8, email: []const u8 };
    const body = try c.bodyJson(User);
    return c.json(.{ .created = true, .name = body.name }, .{ .status = .created });
}
```

```bash
zig build run
# Server listening on http://127.0.0.1:3000
# Starting 12 worker threads
```

`listen` accepts both `port` and `host` — any field not set falls back to the values in `spider.config.zig`:

```zig
.listen(.{ .port = 8080 })                          // override port only
.listen(.{ .host = "0.0.0.0" })                     // override host only
.listen(.{ .port = 8080, .host = "0.0.0.0" })       // override both
.listen(.{})                                         // use config values
```

---

## Context — `c: *spider.Ctx`

Every handler receives a `*spider.Ctx`. It provides everything you need — no allocators, no I/O wiring required.

### Responses

```zig
// JSON
return c.json(.{ .id = 1, .name = "Alice" }, .{});

// JSON with custom status
return c.json(.{ .error = "not found" }, .{ .status = .not_found });

// JSON with custom headers
return c.json(.{ .ok = true }, .{
    .headers = &.{.{ "X-Powered-By", "Spider" }},
});

// Plain text
return c.text("Hello!", .{});

// HTML
return c.html("<h1>Hello</h1>", .{});

// Redirect
return c.redirect("/dashboard");

// Render template by name (auto-detects .html/.md extension)
return c.view("users/index", .{ .users = users }, .{});

// Render template string directly
return c.render("Hello { name }!", .{ .name = "World" }, .{});
```

### Reading Requests

```zig
// URL parameter: /users/:id
const id = c.param("id") orelse "unknown";

// Query string: /search?q=zig
const q = c.query("q") orelse "";

// Request header
const ua = c.header("User-Agent") orelse "";

// Cookie
const session = c.cookie("token") orelse "";

// Raw body
const raw = c.getBody() orelse "";

// Parse JSON body
const User = struct { name: []const u8, email: []const u8 };
const user = try c.bodyJson(User);

// Parse form body (auto-detects url-encoded and multipart)
const input = try c.parseForm(FormInput);

// Parse multipart form (when you need file uploads)
const mp = try c.parseMultipart();
const title = mp.getValue("title") orelse "";
const files = mp.getFile("avatar") orelse &.{};
```

### Arena Allocator

```zig
// Allocate freely — Spider cleans up after each request
const msg = try std.fmt.allocPrint(c.arena, "Hello, {s}!", .{name});
return c.json(.{ .message = msg }, .{});
```

### HTMX Detection

```zig
fn handler(c: *spider.Ctx) !spider.Response {
    if (c.isHtmx()) {
        // return partial HTML fragment
        return c.view("users/_list", data, .{});
    }
    // return full page
    return c.view("users/index", data, .{});
}
```

### Cookies

```zig
// Read a cookie
const token = c.cookie("session") orelse "";

// Set a cookie (returns the Set-Cookie string)
const cookie = try c.setCookie("session", jwt, .{
    .http_only = true,
    .secure = true,
    .same_site = "Lax",
    .path = "/",
    .max_age = 86400 * 7,
});

// Set a cookie via ResponseOptions helper
const opts = try c.withCookie("session", jwt, .{
    .max_age = 86400,
});

// Include cookie in response
return c.json(.{ .ok = true }, .{
    .headers = &.{.{ "Set-Cookie", cookie }},
});
```

### Database inside Context

```zig
// If you've registered a database via server.db(), use c.db()
pub fn handler(c: *spider.Ctx) !spider.Response {
    const users = try c.db().query(User, "SELECT * FROM users WHERE active = $1", .{true});
    return c.json(users, .{});
}
```

---

## Routing

```zig
server
    .get("/", homeHandler)
    .post("/users", createUser)
    .get("/users/:id", getUser)
    .put("/users/:id", updateUser)
    .delete("/users/:id", deleteUser)
    .patch("/users/:id", patchUser)
    .head("/users/:id", headUser);
```

### Route Groups

Groups allow sharing middleware across a set of routes.

```zig
fn dashboardRoutes(s: *spider.Server, prefix: []const u8, mws: []const spider.MiddlewareFn) void {
    s.addRoute(.GET, "/dashboard", mws, dashHandler);
    s.addRoute(.GET, "/dashboard/users", mws, usersHandler);
}

server
    .group("/dashboard", &.{authMiddleware}, dashboardRoutes)
    .get("/login", loginHandler);
```

### Route-specific Middleware

```zig
// Register a route with specific middlewares
server.addRoute(.POST, "/admin/users", &.{authMiddleware, adminMiddleware}, createUser);
```

---

## Middleware

```zig
// Global — applies to all routes
server.use(loggerMiddleware);

// By path prefix
server.useAt("/api/*", apiMiddleware);

// Per group
server.group("/admin", &.{authMiddleware, adminMiddleware}, adminRoutes);

// Global error handler
server.onError(errorHandler);
```

### Writing Middleware

```zig
fn loggerMiddleware(c: *spider.Ctx, next: spider.NextFn) !spider.Response {
    std.log.info("{s} {s}", .{ c.getMethod(), c.getPath() });
    const res = try next(c);
    std.log.info("  → {d}", .{@intFromEnum(res.status)});
    return res;
}

fn authMiddleware(c: *spider.Ctx, next: spider.NextFn) !spider.Response {
    const token = c.cookie("token") orelse
        return c.redirect("/login");
    _ = try spider.auth.jwtVerify(spider.auth.Claims, c.arena, c._io, token, secret);
    return next(c);
}
```

### Built-in Logger Middleware

Spider includes a colorized request logger:

```zig
server.use(spider.logger);
// GET  /users  200  12ms
// POST /api    401  3µs
```

---

## Templates

Spider's template engine uses an **AST parser** with support for variables, loops, conditions, includes, layout inheritance, **components** (PascalCase), **named slots**, and **Markdown**.

### Template Syntax

```html
<!-- views/layout.html -->
<!DOCTYPE html>
<html>
<body>
<nav>My App</nav>
<main>{ slot }</main>
</body>
</html>
```

```html
<!-- views/users/index.html -->
extends "layout"
<h1>Users</h1>
for (users) |user| {
  <li>{ user.name } — { user.email }</li>
}
```

```zig
// Handler — just the name, Spider handles the rest
fn usersHandler(c: *spider.Ctx) !spider.Response {
    const users = try db.query(User, "SELECT * FROM users", .{});
    return c.view("users/index", .{ .users = users }, .{});
}
```

### Conditionals

```html
if (user.active) {
  <span class="badge">Active</span>
} else {
  <span class="badge muted">Inactive</span>
}
// else if chains
if (role == "admin") {
  <li>Admin Panel</li>
} else if (role == "moderator") {
  <li>Moderator Tools</li>
} else {
  <li>Standard User</li>
}
```

### Coalescing (defaults)

```html
<p>Hello, { name ?? "Guest" }</p>
```

### List length

```html
if (users.len > 0) {
  <p>{ users.len } users found</p>
}
```

### Components (PascalCase)

Create reusable components with PascalCase naming:

```html
<!-- views/components/UserInfo.html -->
<div class="user-card">
<h3>{ name }</h3>
<p>{ email }</p>
{ slot }
</div>
```

```html
<!-- Usage in another template -->
<UserInfo name="Alice" email="alice@spider.dev">
  <p>Extra content here</p>
</UserInfo>
<!-- Self-closing (no slot content) -->
<UserInfo name="Bob" email="bob@spider.dev" />
```

### Named Slots

```html
<!-- views/components/PageLayout.html -->
<header>{ slot_header }</header>
<main>{ slot }</main>
<aside>{ slot_sidebar }</aside>
<!-- Usage -->
<PageLayout>
  <h1 slot="header">Dashboard</h1>
  <p>Welcome back!</p>
  <nav slot="sidebar">...</nav>
</PageLayout>
```

### Markdown Support

Spider auto-detects Markdown files via `--doc` signature in frontmatter:

```markdown
<!-- views/docs/api.md -->
--doc
title: API Documentation
layout: docs_layout
--
# API Reference
Welcome to the API docs...
```

```zig
// Handler — auto-detects .md extension
return c.view("docs/api", .{}, .{});
```

### Template Tags

| Tag | Description |
|-----|-------------|
| `{ variable }` | Variable interpolation |
| `{ variable ?? "default" }` | Coalescing operator (default value) |
| `if (condition) { ... }` | Conditional |
| `if (a) { ... } else if (b) { ... } else { ... }` | If / else if / else |
| `for (items) \|item\| { ... }` | Loop with capture |
| `extends "layout"` | Layout inheritance (top of file) |
| `<ComponentName prop="value">` | PascalCase component (with slot) |
| `<ComponentName prop="value" />` | Self-closing component |
| `{ slot }` | Default slot content |
| `{ slot_name }` | Named slot content |

#### HTML escaping

`{ variable }` is HTML-escaped (`& < > " '`), in text and in attribute
values alike, so data from users can't inject markup or break out of an
attribute. What is emitted verbatim is the template's own markup: slots,
literal component props (`<Badge label="A &amp; B" />`), helper calls, and
values your code explicitly marks as trusted with `spider.RawHtml`:

```zig
// Only for markup your code built (or already escaped) — never user input.
return c.view("page", .{ .qr = spider.RawHtml{ .html = svg } }, .{});
```

`RawHtml` also works as an optional (`?RawHtml`) and inside structs and
slices. `<script>`/`<style>` bodies are never interpolated.

### Template Modes

Spider has two template modes. Both produce **byte-identical output** — the only difference is when templates are loaded.

**Embed mode** — templates compiled into the binary (recommended for production):

```zig
// root.zig or main.zig — one line enables embed mode
pub const spider_templates = @import("embedded_templates.zig").EmbeddedTemplates;
```

Spider automatically generates `embedded_templates.zig` on every `zig build` by scanning `src/` recursively for `.html` and `.md` files. The build helper (`spider_build.setup`) handles this automatically.

**Runtime mode** — reads from disk at request time (useful in development):

```zig
// main.zig — nothing needed, just don't declare spider_templates
// Spider scans views_dir and serves templates from disk
```

Detection uses `@hasDecl(@import("root"), "spider_templates")` — same pattern as `std_options` in the Zig stdlib.

#### spider.config.zig

When using runtime mode, create `spider.config.zig` in your project root to configure the template directory:

```zig
// spider.config.zig
const spider = @import("spider");

pub const config = spider.Config{
    .views_dir = "./src",   // point to where your .html/.md files live
    .layout = "layout",
    .env = .development,
    .port = 3000,
    .host = "0.0.0.0",
};
```

Spider prints warnings to help diagnose issues:

```
[spider] WARNING: views_dir "./views" not found.
[spider]          Templates will not load in runtime mode.

[spider] runtime templates: 5 loaded from "./src"
```

#### Template name normalization

| File path (relative to views_dir) | Normalized name | Call with |
|---|---|---|
| `views/bills/index.html` | `bills_index` | `c.view("bills/index", ...)` |
| `views/home/index.html` | `home_index` | `c.view("home/index", ...)` |
| `shared/templates/layout.html` | `layout` | layout (auto, via config) |
| `shared/templates/Card.html` | `Card` | `c.view("Card", ...)` |
| `shared/templates/site-nav.html` | `site_nav` | `<SiteNav />` in templates |

Rules: strip extension → use segment after `views/` or `templates/` → replace `/` and `-` with `_`.

---

## Database

### PostgreSQL (Pure Zig)

Spider's PostgreSQL driver is **pure Zig** — no libpq dependency required. It uses a connection pool with retry logic (5 attempts, exponential backoff) and supports parameterized queries (`$1`, `$2`, ...).

> Obrigado ao [karlseguin](https://github.com/karlseguin) pelo excelente [pg.zig](https://github.com/karlseguin/pg.zig) — projeto que serviu de base para o driver PostgreSQL do Spider. Utilizamos um fork customizado para atender às necessidades do framework.


```zig
const std = @import("std");
const spider = @import("spider");
const db = spider.pg;

pub fn main() !void {
    // Initialize — reads env vars with fallback defaults
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    try db.init(io, .{});
    defer db.deinit();

    var server = spider.app(.{});
    defer server.deinit();

    server
        .get("/users", listUsers)
        .listen(.{ .port = 3000 }) catch {};
}
```

All `DbConfig` fields are optional — they fall back to environment variables:

| Field | Env var | Default |
|-------|---------|---------|
| `.host` | `PG_HOST` | `"localhost"` |
| `.port` | `PG_PORT` | `5432` |
| `.user` | `PG_USER` | `"spider"` |
| `.password` | `PG_PASSWORD` | `"spider"` |
| `.database` | `PG_DB` | `"spider_db"` |
| `.pool_size` | — | `10` |

So `try db.init(io, .{});` reads everything from your `.env` file.

#### Queries

`db.query(T, arena, sql, params)` returns `[]T` for structs, `i32` for counts, `void` for INSERT/UPDATE/DELETE.

```zig
const User = struct { id: i32, name: []const u8, email: []const u8 };

// SELECT — returns []User allocated in c.arena
fn listUsers(c: *spider.Ctx) !spider.Response {
    const users = try db.query(User, c.arena,
        "SELECT id, name, email FROM users WHERE active = $1",
        .{true},
    );
    return c.json(users, .{});
}

// SELECT one row — returns ?User
fn getUser(c: *spider.Ctx) !spider.Response {
    const id = try std.fmt.parseInt(i32, c.param("id") orelse "0", 10);
    const user = try db.queryOne(User, c.arena,
        "SELECT id, name, email FROM users WHERE id = $1",
        .{id},
    ) orelse return c.json(.{ .error = "not found" }, .{ .status = .not_found });
    return c.json(user, .{});
}

// COUNT — returns i32
fn countUsers(c: *spider.Ctx) !spider.Response {
    const count = try db.query(i32, c.arena, "SELECT COUNT(*) FROM users", .{});
    return c.json(.{ .count = count }, .{});
}

// INSERT — void
fn createUser(c: *spider.Ctx) !spider.Response {
    const Input = struct { name: []const u8, email: []const u8 };
    const body = try c.bodyJson(Input);
    try db.query(void, c.arena,
        "INSERT INTO users (name, email) VALUES ($1, $2)",
        .{ body.name, body.email },
    );
    return c.json(.{ .created = true }, .{ .status = .created });
}
```

#### ANY() with array()

```zig
fn batchUsers(c: *spider.Ctx) !spider.Response {
    const ids = [_]i32{ 1, 2, 3 };
    const rows = try db.query(User, c.arena,
        "SELECT id, name, email FROM users WHERE id = ANY($1)",
        .{db.array(i32, &ids)},
    );
    return c.json(rows, .{});
}
```

#### Transactions

```zig
fn transferHandler(c: *spider.Ctx) !spider.Response {
    var tx = try db.begin();
    defer tx.rollback();

    try tx.query(void, c.arena,
        "UPDATE accounts SET balance = balance - $1 WHERE id = $2",
        .{ amount, from_id },
    );
    try tx.query(void, c.arena,
        "UPDATE accounts SET balance = balance + $1 WHERE id = $2",
        .{ amount, to_id },
    );
    try tx.commit();

    return c.json(.{ .ok = true }, .{});
}
```

#### Raw SQL (no params)

```zig
// Execute multiple statements separated by ';'
try db.queryExecute(void, c.arena,
    "CREATE TEMP TABLE foo (id int); INSERT INTO foo VALUES (1)"
);

// Raw query returning rows
const rows = try db.queryExecute(User, c.arena, "SELECT * FROM users");

// Single row raw query
const user = try db.queryOneExecute(User, c.arena, "SELECT * FROM users LIMIT 1");
```

### SQLite (via libsqlite3)

Requires a C compiler (uses `@import("c_sqlite")`).

```zig
try spider.sqlite.init(arena, .{ .filename = "app.db" });
defer spider.sqlite.deinit();

const Row = struct { id: i32, title: []const u8 };
const rows = try spider.sqlite.query(Row, c.arena,
    "SELECT * FROM todos WHERE done = ?", .{false},
);
```

### MySQL (Pure Zig)

Spider's MySQL driver is **pure Zig** — no libmysqlclient required.

```zig
try spider.mysql.init(arena, io, .{
    .host = "localhost",
    .database = "myapp",
    .user = "root",
    .password = "",
});
defer spider.mysql.deinit();

const Row = struct { id: i32, name: []const u8 };
const rows = try spider.mysql.query(Row, c.arena,
    "SELECT * FROM products WHERE price > ?", .{100},
);
```

### Database Driver Interface (ORM-friendly)

Spider provides a vtable-based database interface for driver-agnostic code:

```zig
// Register the database with the server
const driver = spider.pg.PgDriver{};
server.db(driver.database());

// Use it from any handler via c.db()
fn handler(c: *spider.Ctx) !spider.Response {
    // Works with any registered driver (pg, mysql, etc.)
    const users = try c.db().query(User, "SELECT * FROM users", .{});
    return c.json(users, .{});
}

// Execute raw SQL on the registered driver
try c.db().exec("CREATE INDEX idx_users_email ON users(email)");
```

---

## Authentication

### JWT

```zig
const auth = spider.auth;

// Sign
const token = try auth.jwtSign(c.arena, .{
    .sub = user.id,
    .email = user.email,
    .name = user.name,
    .exp = 9999999999,
}, spider.env.getOr("JWT_SECRET", "changeme"));

// Verify (note: requires c._io)
const Claims = struct { sub: i32, email: []const u8, name: []const u8, exp: i64 };
const claims = try auth.jwtVerify(Claims, c.arena, c._io, token, secret);

// Set cookie
const cookie = try c.setCookie("token", token, .{});
return c.json(.{ .ok = true }, .{
    .headers = &.{.{ "Set-Cookie", cookie }},
});

// Clear cookie (logout)
const cookie = try c.setCookie("token", "", .{ .max_age = 0 });
```

```zig
// Legacy cookie helpers (still available in auth module)
const cookie = try auth.cookieSet(c.arena, token);
const clear = try auth.cookieClear(c.arena);
```

### Auth Middleware

```zig
var gAuth = spider.auth.Auth.init(.{
    .secret = spider.env.getOr("JWT_SECRET", "changeme"),
    .public_paths = &.{ "/login", "/auth/*" },
    .redirect_to = "/login",
    .secure_cookie = false, // true in production
});

server
    .get("/login", loginHandler)
    .group("/dashboard", &.{gAuth.asFn()}, dashboardRoutes);
```

### Google OAuth

```zig
const google = spider.google;

const googleConfig = google.GoogleConfig{
    .client_id     = spider.env.getOr("GOOGLE_CLIENT_ID", ""),
    .client_secret = spider.env.getOr("GOOGLE_CLIENT_SECRET", ""),
    .redirect_uri  = spider.env.getOr("GOOGLE_REDIRECT_URI", ""),
};

// Redirect to Google
fn loginHandler(c: *spider.Ctx) !spider.Response {
    const url = try google.authUrl(c.arena, googleConfig);
    return c.redirect(url);
}

// Handle callback
fn callbackHandler(c: *spider.Ctx) !spider.Response {
    const code = c.query("code") orelse return c.redirect("/login");
    const profile = try google.fetchProfile(c, code, googleConfig);

    const token = try spider.auth.jwtSign(c.arena, .{
        .sub = 0,
        .email = profile.email,
        .name = profile.name,
        .exp = 9999999999,
    }, spider.env.getOr("JWT_SECRET", "changeme"));

    const cookie = try c.setCookie("token", token, .{});
    return c.redirect("/");
}
```

### Clerk OAuth

```zig
const clerk = try spider.clerk.Clerk.init(c.arena, c._io, .{
    .publishable_key = spider.env.getOr("CLERK_PUBLISHABLE_KEY", ""),
    .secret_key = spider.env.getOr("CLERK_SECRET_KEY", ""),
    .redirect_uri = "http://localhost:3000/auth/callback",
});
defer clerk.deinit();

server
    .get("/login", userLoginHandler)
    .get("/auth/callback", clerk.callbackHandler())
    .group("/dashboard", &.{clerk.middleware()}, dashboardRoutes);

fn userLoginHandler(c: *spider.Ctx) !spider.Response {
    const url = try clerk.authUrl(c.arena);
    return c.redirect(url);
}
```

### Keycloak OAuth (with Refresh Token)

```zig
const kc = try spider.keycloak.Keycloak.init(c.arena, c._io, .{
    .base_url = spider.env.getOr("KEYCLOAK_URL", "http://localhost:8080"),
    .realm = spider.env.getOr("KEYCLOAK_REALM", "myapp"),
    .client_id = spider.env.getOr("KEYCLOAK_CLIENT_ID", ""),
    .client_secret = spider.env.getOr("KEYCLOAK_CLIENT_SECRET", ""),
    .redirect_uri = "http://localhost:3000/auth/callback",
});
defer kc.deinit();

server
    .get("/auth/login", kc.loginHandler())
    .get("/auth/callback", kc.callbackHandler())
    .get("/auth/refresh", kc.refreshHandler()) // auto-refresh expired tokens
    .group("/dashboard", &.{kc.middleware()}, dashboardRoutes);
```

### JWKS-based Auth (Generic)

For any provider that exposes JWKS endpoints (Auth0, Firebase, etc.):

```zig
const jwks = try spider.jwks.JwksAuth.init(c.arena, c._io, .{
    .jwks_url = "https://example.com/.well-known/jwks.json",
    .issuer = "https://example.com/",
    .cookie_name = "__session",
    .login_path = "/login",
    .refresh_path = "/auth/refresh",
});
defer jwks.deinit();

server
    .group("/api", &.{jwks.middleware()}, apiRoutes);
```

---

## WebSocket

Spider's WebSocket support uses the `server.ws()` method for a clean handler interface:

```zig
fn chatHandler(w: *spider.Ws) !void {
    // Join a channel
    try w.join("room:general");

    while (try w.next()) |msg| {
        switch (msg.type) {
            .text => {
                // Send to specific user
                try w.send("Message received");

                // Broadcast to channel
                w.broadcastTo("room:general", msg.data);

                // Broadcast to all connected clients
                w.broadcast(msg.data);
            },
            .binary => {},
        }
    }
}

server.ws("/ws/chat", chatHandler);
```

### WebSocket API

| Method | Description |
|--------|-------------|
| `w.next()` | Wait for next message (returns `?Message`) |
| `w.send(text)` | Send text message to this connection |
| `w.broadcast(text)` | Broadcast to all connections |
| `w.broadcastTo(channel, text)` | Broadcast to a channel |
| `w.broadcastFmt(fmt, args)` | Broadcast formatted text |
| `w.broadcastToFmt(channel, fmt, args)` | Broadcast formatted to channel |
| `w.join(channel)` | Join a channel |
| `w.joinUser(user_id)` | Join user-specific channel (`user:{id}`) |

### WebSocket with Interval (Heartbeat / Periodic Broadcast)

```zig
fn broadcastStats(hub: *spider.Hub) void {
    hub.broadcast("heartbeat");
}

server.wsInterval("/ws/stats", 5000, broadcastStats);
```

This creates a WebSocket endpoint that automatically broadcasts the callback result every `N` milliseconds.

### Direct Hub Access

From any handler, access the WebSocket hub to broadcast externally:

```zig
fn someHandler(c: *spider.Ctx) !spider.Response {
    const hub = c.wsHub();
    hub.broadcast("Event from HTTP handler!");
    hub.broadcastToChannel("room:admin", "Admin notification");
    hub.notifyUser(42, "private_msg", .{ .text = "Secret!" });
    return c.json(.{ .ok = true }, .{});
}
```

---

## Server-Sent Events (SSE)

```zig
fn sseHandler(sse: *spider.Sse) !void {
    try sse.join("notifications");

    while (true) {
        try sse.send("ping", .{ .time = "2024-01-01T00:00:00Z" });
        // Keep connection alive
        sse.wait();
    }
}

server.sse("/events", sseHandler);
```

### SSE API

| Method | Description |
|--------|-------------|
| `s.send(event, data)` | Send an event (data is JSON-serialized) |
| `s.join(channel)` | Join a channel |
| `s.joinUser(user_id)` | Join user-specific channel |
| `s.wait()` | Block until connection closes |
| `s.param(key)` | Access URL parameters |

### Hub Events (Structured Messages)

The Hub supports structured event/data messages for SSE:

```zig
const hub = c.sseHub();

// Emit to all SSE connections
hub.emit("notification", .{ .title = "New message", .body = "Hello!" });

// Emit to a channel
hub.emitTo("user:42", "private", .{ .msg = "Secret" });

// Notify a specific user
hub.notifyUser(42, "alert", .{ .type = "info" });
```

---

## Web Push Notifications

Spider includes a full Web Push implementation (RFC 8291, RFC 8292) with VAPID.

### Generate VAPID Keys

```zig
var threaded = std.Io.Threaded.init_single_threaded;
const io = threaded.io();
const keys = spider.push.WebPush.generateKeys(io);
// Store keys.private_key and keys.public_key
```

Or via CLI:

```bash
spider generate-vapid mailto:admin@example.com
```

### Send Push Notification

```zig
const wp = spider.push.WebPush.init(.{
    .subject = "mailto:admin@example.com",
    .private_key = spider.env.getOr("VAPID_PRIVATE_KEY", ""),
    .public_key = spider.env.getOr("VAPID_PUBLIC_KEY", ""),
});

// Or load from env
const wp = spider.push.WebPush.initFromEnv();

// From a handler
try wp.send(c, .{
    .endpoint = "https://fcm.googleapis.com/...",
    .p256dh = "...",
    .auth = "...",
}, "Hello Push!", 3600);
```

**Requirements:** Uses `spider.http_client` (pacman) under the hood — no external dependencies.

---

## Cloudflare R2 Object Storage

Spider provides a full R2 client with AWS Signature V4.

```zig
const r2 = spider.r2.R2.init(.{
    .account_id = spider.env.getOr("R2_ACCOUNT_ID", ""),
    .access_key = spider.env.getOr("R2_ACCESS_KEY", ""),
    .secret_key = spider.env.getOr("R2_SECRET_KEY", ""),
    .bucket = spider.env.getOr("R2_BUCKET", ""),
    .pub_url = spider.env.getOr("R2_PUBLIC_URL", ""),
});

// Or load from env
const r2 = spider.r2.R2.initFromEnv();
```

### Operations

```zig
// Upload
try r2.put(c, "folder/file.txt", file_content, "text/plain");

// Download
const data = try r2.get(c, "folder/file.txt");

// Delete
try r2.delete(c, "folder/file.txt");

// Check existence
const exists = try r2.head(c, "folder/file.txt");

// Presigned URL for direct browser upload
const url = try r2.presignedPut(c.arena, "uploads/file.pdf", "application/pdf", 3600);

// Public URL
const pub = try r2.publicUrl(c.arena, "folder/file.txt");
```

---

## Multipart Uploads

Spider supports `multipart/form-data` parsing for file uploads.

### Parsing Uploaded Files

```zig
fn uploadHandler(c: *spider.Ctx) !spider.Response {
    const mp = try c.parseMultipart();
    defer mp.deinit();

    // Access text fields
    const description = mp.getValue("description") orelse "";

    // Access uploaded files
    const files = mp.getFile("avatar") orelse &.{};
    for (files) |file| {
        std.log.info("upload: {s} ({d} bytes, {s})", .{
            file.filename, file.size, file.content_type,
        });
        // file.data contains the raw bytes
    }

    return c.json(.{ .uploaded = files.len }, .{});
}
```

### Typed Form Parsing (auto-detects multipart vs url-encoded)

```zig
const FormInput = struct {
    name: []const u8,
    email: []const u8,
    age: i32,
};

fn formHandler(c: *spider.Ctx) !spider.Response {
    const input = try c.parseForm(FormInput);
    return c.json(.{ .name = input.name, .email = input.email }, .{});
}
```

---

## Dependency Injection (Decorators)

Spider supports automatic dependency injection into handlers using `spider.app(decorations)`:

```zig
const AppDeps = struct {
    pool: *PgPool,
    email: *EmailService,
    config: AppConfig,
};

fn main() !void {
    const deps = AppDeps{
        .pool = &pool,
        .email = &email_service,
        .config = app_config,
    };

    var server = spider.app(deps);
    defer server.deinit();

    server
        .get("/", homeHandler)
        .listen(.{ .port = 3000 }) catch {};
}

// Handler receives dependencies automatically — no manual wiring needed
fn homeHandler(c: *spider.Ctx, pool: *PgPool, email: *EmailService) !spider.Response {
    const users = try pool.query(...);
    try email.sendWelcome(...);
    return c.json(.{ .ok = true }, .{});
}
```

Up to **4 extra parameters** beyond `*spider.Ctx` are supported. The type of each parameter must match a field in the decorations struct — otherwise you get a clear compile error.

---

## Static Files

Spider automatically serves `./public/` at `/` — no configuration needed.

```
public/
├── css/
│   └── app.css       → GET /css/app.css
├── js/
│   └── app.js        → GET /js/app.js
└── logo.png          → GET /logo.png
```

Path traversal (`../../etc/passwd`) is blocked automatically.

### Custom Static Directory

```zig
// Serve from a different directory
server.staticDir("./assets");

// Serve with a different prefix
server.staticAt("./uploads", "/media");
// /media/images/logo.png → ./uploads/images/logo.png
```

---

## Live Reload

Spider auto-injects WebSocket live reload in development mode:

```zig
// spider.config.zig
pub const config = spider.Config{
    .env = .development, // enables live reload
};
```

When you save a template or static file, the browser refreshes automatically. No configuration needed — just run `zig build run` in dev mode.

---

## Health Endpoints

When using `spider.app()` or `spider.appWithConfig()`, two health endpoints are registered automatically:

| Endpoint | Description |
|----------|-------------|
| `GET /up` | Simple health check — returns `"OK"` |
| `GET /_spider/health` | JSON with status and uptime in seconds |

In development mode, a live-reload WebSocket is also registered at `/_spider/reload`.

---

## Metrics

Spider provides global request metrics:

```zig
const snapshot = spider.metrics.snapshot(io);
std.log.info("requests: {d}, errors: {d}", .{
    snapshot.total_requests,
    snapshot.errors,
});
```

Metrics tracked: total requests, errors, bytes in/out, slow requests, WebSocket clients.

---

## Environment Configuration

Spider automatically loads `.env` files on startup with priority order:

1. `.env` — base configuration
2. `.env.development` or `.env.production` — environment-specific
3. `.env.local` — local overrides (highest priority)

```bash
# .env
DATABASE_URL=postgres://localhost/myapp
JWT_SECRET=my-secret-key
PORT=3000
DEBUG=true
GOOGLE_CLIENT_ID=your-client-id
```

```zig
// Access anywhere in your app
const host = spider.env.getOr("DB_HOST", "localhost");
const port = spider.env.getInt(u16, "PORT", 3000);
const debug = spider.env.getBool("DEBUG", false);
const secret = spider.env.get("JWT_SECRET"); // returns ?[]const u8
```

---

## Configuration

Create `spider.config.zig` in your project root:

```zig
// spider.config.zig
const spider = @import("spider");

pub const config = spider.Config{
    .port = 3000,
    .host = "127.0.0.1",
    .views_dir = "./src",
    .layout = "layout",
    .static_dir = "./public",
    .env = .development,
    .workers = null, // defaults to CPU count
    // Connection deadlines (ms, 0 = off) — idle/stalled clients can't hold
    // file descriptors forever. Never applied while a handler runs, so SSE,
    // WebSocket and slow handlers are unaffected.
    .keepalive_timeout_ms = 120_000, // waiting for the next request
    .header_timeout_ms = 30_000, // first byte -> complete request head
    .body_timeout_ms = 60_000, // longest silence while receiving a body
};
```

Or configure inline via `spider.appWithConfig()`:

```zig
var server = spider.appWithConfig(spider.Config{
    .port = 8080,
    .env = .production,
});
```

---

## CLI Tool

Spider ships with a `spider` CLI for project scaffolding:

```bash
# Create a new project
spider new myapp
spider new myapp --daisyui                       # With DaisyUI preset
spider new myapp --skip-downloads                # Skip binary downloads (tailwindcss, alpine, htmx)

# Generate code
spider generate feature <name>                   # Full CRUD feature
spider generate auth --provider=keycloak         # Auth with Keycloak
spider generate auth --provider=google           # Auth with Google

# Generate VAPID keys for Web Push
spider generate-vapid mailto:admin@example.com

# Run migrations
spider migrate

# Show version
spider version
# spider v0.6.9
```

---

## HTTP Client

Spider bundles a full HTTP client (`pacman`) accessible via:

```zig
const http = spider.http_client;

var res = try http.get(io, arena, "https://api.example.com/users", .{});
defer res.deinit();

// Parse JSON response
const data = try res.json(ResponseType);
defer data.deinit();

// POST with JSON body
var res = try http.post(io, arena, "https://api.example.com/users", .{
    .body = .{ .json = .{ .name = "Alice" } },
});

// POST with form data
var res = try http.post(io, arena, "https://api.example.com/token", .{
    .body = .{ .form = &.{
        .{ "grant_type", "authorization_code" },
        .{ "code", code },
    } },
});
```

---

## Project Structure

```
src/
├── spider.zig              — Public API (all exports)
├── core/
│   ├── app.zig             — Server, routing, workers, DI, WebSocket/SSE handlers
│   ├── context.zig         — Ctx, Response, ResponseOptions, CookieOptions
│   └── database.zig        — Database vtable interface
├── routing/
│   ├── router.zig          — Trie router (static + dynamic routes)
│   └── group.zig           — Route groups
├── modules/
│   ├── auth/auth.zig       — JWT sign/verify, cookie helpers, Auth middleware
│   ├── static.zig          — Static file serving
│   ├── dashboard.zig       — Built-in metrics dashboard
│   ├── livereload.zig      — Live reload (dev mode)
│   ├── health.zig          — /up and /_spider/health endpoints
│   ├── push.zig            — Web Push (RFC 8291/8292)
│   ├── r2.zig              — Cloudflare R2 (AWS SigV4)
│   └── logger.zig          — Colorized request logger middleware
├── drivers/
│   ├── pg/pg.zig           — PostgreSQL driver (pure Zig, pool-based)
│   ├── sqlite/sqlite.zig   — SQLite driver (via libsqlite3 C binding)
│   └── mysql/              — MySQL driver (pure Zig wire protocol)
├── render/
│   ├── template.zig        — Template engine entry point
│   ├── views.zig           — Template resolver (embed + runtime)
│   ├── ast.zig             — AST node types
│   ├── parser.zig          — Template parser
│   ├── renderer.zig        — Template renderer
│   ├── context.zig         — Template rendering context
│   └── zmd/                — Markdown to HTML renderer
├── internal/
│   ├── config.zig          — spider.Config
│   ├── env.zig             — .env loader
│   ├── logger.zig          — Structured logging
│   ├── metrics.zig         — Request/error metrics
│   └── buffer_pool.zig     — Buffer pooling
├── ws/
│   ├── websocket.zig       — WebSocket protocol (RFC 6455)
│   ├── hub.zig             — Broadcast hub (WebSocket + SSE)
│   ├── ws.zig              — Ws handler interface (next, send, broadcast, join)
│   └── sse.zig             — SSE handler interface (send, join, wait)
├── binding/
│   ├── form.zig            — URL-encoded form parsing
│   ├── form_parser.zig     — Typed form binding (struct mapping)
│   └── multipart.zig       — Multipart/form-data parsing
├── providers/
│   ├── google.zig          — Google OAuth
│   ├── clerk.zig           — Clerk OAuth + JWKS middleware
│   ├── jwks.zig            — JWKS key fetching + JWT verification
│   └── keycloak.zig        — Keycloak OAuth + refresh token
├── cli/
│   ├── main.zig            — CLI entry point
│   ├── new.zig             — `spider new` project scaffolding
│   ├── generate.zig        — `spider generate` code generation
│   ├── migrate.zig         — `spider migrate` runner
│   ├── generate_vapid.zig  — VAPID key generation
│   └── templates/          — Scaffolding templates
├── features/               — Built-in features (scaffolded code)
├── build_helpers.zig       — spider_build.setup() helper
└── generate_templates.zig  — embedded_templates.zig generator
```

---

## API Reference

### `spider.Ctx` Methods

| Method | Description |
|--------|-------------|
| `c.json(data, opts)` | JSON response |
| `c.text(content, opts)` | Plain text response |
| `c.html(content, opts)` | HTML response |
| `c.view(name, data, opts)` | Render template by name |
| `c.render(tmpl, data, opts)` | Render template string directly |
| `c.redirect(url)` | HTTP redirect (302) |
| `c.param(name)` | URL parameter |
| `c.query(name)` | Query string parameter |
| `c.header(name)` | Request header |
| `c.cookie(name)` | Request cookie |
| `c.getBody()` | Raw request body |
| `c.bodyJson(T)` | Parse JSON body into struct |
| `c.parseForm(T)` | Parse form body (auto-detects url-encoded + multipart) |
| `c.parseMultipart()` | Parse multipart/form-data (returns MultipartData) |
| `c.setCookie(name, value, opts)` | Build Set-Cookie string |
| `c.withCookie(name, value, opts)` | Build ResponseOptions with cookie |
| `c.isHtmx()` | True if HX-Request header present |
| `c.isBoosted()` | True if HX-Boosted header present |
| `c.db()` | DatabaseCtx for driver-agnostic queries |
| `c.wsHub()` | WebSocket Hub (must be in ws route) |
| `c.sseHub()` | SSE Hub (must be in sse route) |
| `c.getPath()` | Request path |
| `c.getMethod()` | Request method string |
| `c.arena` | Per-request arena allocator |

### `spider.ResponseOptions`

```zig
pub const ResponseOptions = struct {
    status: std.http.Status = .ok,
    headers: []const [2][]const u8 = &.{},
    cookies: []const [2][]const u8 = &.{},
};
```

### `spider.CookieOptions`

```zig
pub const CookieOptions = struct {
    value: []const u8 = "",
    http_only: bool = true,
    secure: bool = true,
    same_site: []const u8 = "Lax",
    path: []const u8 = "/",
    max_age: ?u32 = null,
};
```

### `spider.Server` Methods

| Method | Description |
|--------|-------------|
| `server.get(path, handler)` | Register GET route |
| `server.post(path, handler)` | Register POST route |
| `server.put(path, handler)` | Register PUT route |
| `server.delete(path, handler)` | Register DELETE route |
| `server.patch(path, handler)` | Register PATCH route |
| `server.head(path, handler)` | Register HEAD route |
| `server.ws(path, handler)` | Register WebSocket route |
| `server.wsInterval(path, ms, callback)` | WebSocket with periodic broadcast |
| `server.sse(path, handler)` | Register SSE route |
| `server.use(middleware)` | Global middleware |
| `server.useAt(path, middleware)` | Path-scoped middleware |
| `server.group(prefix, mws, fn)` | Route group with middleware |
| `server.onError(handler)` | Global error handler |
| `server.addRoute(method, path, mws, handler)` | Route with middleware |
| `server.db(database)` | Register database driver |
| `server.staticDir(dir)` | Set static files directory |
| `server.staticAt(dir, prefix)` | Static dir with custom prefix |
| `server.health(path, handler)` | Alias for server.get |
| `server.listen(options)` | Start server |

### `spider.pg` Methods (aliased as `const db = spider.pg`)

| Method | Description |
|--------|-------------|
| `db.init(io, config)` | Initialize pool (DbConfig with optional overrides) |
| `db.deinit()` | Shutdown pool |
| `db.query(T, arena, sql, params)` | Parameterized query → `[]T`, `i32`, or `void` |
| `db.queryOne(T, arena, sql, params)` | Parameterized query → `?T` (single row) |
| `db.queryExecute(T, arena, sql)` | Raw SQL without params |
| `db.queryOneExecute(T, arena, sql)` | Raw SQL single row |
| `db.array(T, values)` | Create array param for `ANY($1)` |
| `db.begin()` | Start transaction → `Transaction` |
| `tx.query(T, arena, sql, params)` | Query inside transaction |
| `tx.queryOne(T, arena, sql, params)` | Single row inside transaction |
| `tx.commit()` | Commit transaction |
| `tx.rollback()` | Rollback transaction |

### `spider.Ws` Methods

| Method | Description |
|--------|-------------|
| `w.next()` | Wait for next message (`?Message`) |
| `w.send(text)` | Send text to this connection |
| `w.broadcast(text)` | Broadcast to all connections |
| `w.broadcastTo(channel, text)` | Broadcast to channel |
| `w.broadcastFmt(fmt, args)` | Broadcast formatted text |
| `w.broadcastToFmt(channel, fmt, args)` | Broadcast formatted to channel |
| `w.join(channel)` | Join a channel |
| `w.joinUser(user_id)` | Join user channel (`user:{id}`) |

### `spider.Sse` Methods

| Method | Description |
|--------|-------------|
| `s.send(event, data)` | Send an event (JSON data) |
| `s.join(channel)` | Join a channel |
| `s.joinUser(user_id)` | Join user channel |
| `s.wait()` | Block until connection closes |

### `spider.Hub` Methods

| Method | Description |
|--------|-------------|
| `hub.broadcast(msg)` | Broadcast to all WS + SSE connections |
| `hub.broadcastToChannel(channel, msg)` | Broadcast to channel |
| `hub.broadcastFmt(fmt, args)` | Broadcast formatted |
| `hub.emit(event, data)` | Emit JSON event (SSE) |
| `hub.emitTo(channel, event, data)` | Emit JSON event to channel |
| `hub.notifyUser(user_id, event, data)` | Notify user `user:{id}` |

---

## Examples

- 🚀 **[SpiderStack](examples/spiderstack/)** — ~~Full-featured starter kit with Google OAuth, PostgreSQL, HTMX, Tailwind, and DaisyUI~~ **Desatualizado — não recomendado no momento**
- 📦 **[local_first](examples/local_first/)** — Local-first architecture example
- 🏗️ **[embed_templates](examples/embed_templates/)** — Template embed mode example
- 🔧 **[c_import_zig_017](examples/c_import_zig_017/)** — C imports with Zig 0.17
- 🔄 **[hot_relead](examples/hot_relead/)** — Hot reload example

---

## Zig Version Policy

Spider tracks Zig `master` — always.

We follow Zig's development branch closely, migrating ahead of each stable release. This means Spider is ready for the new version before it ships, and breaking changes are handled as they happen — not after.

| Version | Status |
|---------|--------|
| `0.17.0-dev` | ✅ current |
| `0.16.0` | ✅ migrated before release |
| `0.15.0` | ✅ migrated before release |

If you're on a stable Zig release and Spider doesn't compile, check the git history — the migration is usually already done.

---

## Author

Built by **Seven** (erivan cerqueira) — follow the journey on
[YouTube](https://www.youtube.com/@llllOllOOl) where Seven posts
videos about Zig and Spider development.

💬 Discord: `llll0ll00ll`

---

## License

MIT
