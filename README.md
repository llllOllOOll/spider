# <img src="assets/spider_logo.png" width="32" height="32" alt="Spider Logo"> Spider

Build web servers in Zig — with the ergonomics you'd expect
from Django or Rails, and the performance you'd expect from C.

Batteries included: PostgreSQL, SQLite, MySQL, JWT auth, Google OAuth, WebSockets, HTMX support, and a powerful template engine.

📖 **Full Documentation:** https://spiderme.org  
🚀 **Starter Kit:** [SpiderStack](https://github.com/llllOllOOll/spider/tree/main/examples/spiderstack)

---

## Requirements

- Zig `0.17.0-dev` or compatible

```bash
zig version
# 0.17.0-dev.93+76174e1bc
```

---

## Installation

```bash
zig fetch --save git+https://github.com/llllOllOOll/spider
```

Add to your `build.zig`:

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

// Auto-generate embedded templates (required for embed mode)
const gen = b.addRunArtifact(spider_dep.artifact("generate-templates"));
gen.addArg("src/");
gen.addArg("src/embedded_templates.zig");
exe.step.dependOn(&gen.step);
```

---

## Quick Start

```zig
const std = @import("std");
const spider = @import("spider");

// Embed templates (one line — Spider detects automatically)
pub const spider_templates = @import("embedded_templates.zig").EmbeddedTemplates;

pub fn main() void {
    var server = spider.app();
    defer server.deinit();

    server
        .get("/", homeHandler)
        .get("/users/:id", userHandler)
        .post("/users", createUserHandler)
        .listen(3000) catch {};
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
# Speed server starting on port 3000...
# Server listening on http://127.0.0.1:3000
# Starting 12 worker threads
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

// Parse form body
const input = try c.parseForm(FormInput);
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

---

## Routing

```zig
server
    .get("/", homeHandler)
    .post("/users", createUser)
    .get("/users/:id", getUser)
    .put("/users/:id", updateUser)
    .delete("/users/:id", deleteUser);
```

### Route Groups

```zig
fn dashboardRoutes(s: *spider.Server, prefix: []const u8, mws: []const spider.MiddlewareFn) void {
    s.addRoute(.GET, "/dashboard", mws, dashHandler);
    s.addRoute(.GET, "/dashboard/users", mws, usersHandler);
}

server
    .group("/dashboard", &.{authMiddleware}, dashboardRoutes)
    .get("/login", loginHandler);
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
    _ = try spider.auth.jwtVerify(Claims, c.arena, token, secret);
    return next(c);
}
```

---

## Templates

Spider's template engine uses an **AST parser** with support for variables, loops, conditions, includes, layout inheritance, **components**, and **Markdown**.

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

### Template Modes

**Embed mode** — templates compiled into the binary (recommended for production):

```zig
// main.zig — one line
pub const spider_templates = @import("embedded_templates.zig").EmbeddedTemplates;
```

Spider automatically generates `embedded_templates.zig` on every `zig build`.

**Runtime mode** — reads from disk (zero config, hot reload in dev):

```zig
// main.zig — nothing needed
// Spider scans src/ and serves templates from disk
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

---

## Database

### PostgreSQL (Pure Zig)

Spider's PostgreSQL driver is **pure Zig** — no libpq dependency required. It uses a connection pool with retry logic (5 attempts, exponential backoff) and supports parameterized queries (`$1`, `$2`, ...).

```zig
const std = @import("std");
const spider = @import("spider");
const db = spider.pg;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    // Initialize — reads env vars with fallback defaults
    try db.init(arena, io, .{
        .host = spider.env.getOr("PG_HOST", "localhost"),
        .port = spider.env.getInt(u16, "PG_PORT", 5432),
        .user = spider.env.getOr("PG_USER", "spider"),
        .password = spider.env.getOr("PG_PASSWORD", "spider"),
        .database = spider.env.getOr("PG_DB", "myapp"),
    });
    defer db.deinit();

    var server = spider.app();
    defer server.deinit();

    server
        .get("/users", listUsers)
        .get("/users/:id", getUser)
        .post("/users", createUser)
        .listen(3000) catch {};
}
```

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

    try tx.query(void, c.arena, "UPDATE accounts SET balance = balance - $1 WHERE id = $2", .{ amount, from_id });
    try tx.query(void, c.arena, "UPDATE accounts SET balance = balance + $1 WHERE id = $2", .{ amount, to_id });
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
```

### SQLite

```zig
try spider.sqlite.init(arena, .{ .path = "app.db" });
defer spider.sqlite.deinit();

const rows = try spider.sqlite.query(Row, c.arena, "SELECT * FROM todos", .{});
```

### MySQL

```zig
try spider.mysql.init(arena, io, .{
    .host = "localhost",
    .database = "myapp",
    .user = "root",
    .password = "",
});
defer spider.mysql.deinit();

const rows = try spider.mysql.query(Row, c.arena, "SELECT * FROM products", .{});
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

// Verify
const Claims = struct { sub: i32, email: []const u8, name: []const u8, exp: i64 };
const claims = try auth.jwtVerify(Claims, c.arena, token, secret);

// Set cookie
const cookie = try auth.cookieSet(c.arena, token);
return c.json(.{ .ok = true }, .{
    .headers = &.{.{ "Set-Cookie", cookie }},
});

// Clear cookie (logout)
const cookie = try auth.cookieClear(c.arena);
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

    const cookie = try spider.auth.cookieSet(c.arena, token);
    return spider.Response{
        .status = .found,
        .body = null,
        .content_type = "text/plain",
        .headers = blk: {
            const h = try c.arena.alloc([2][]const u8, 2);
            h[0] = .{ "Location", "/" };
            h[1] = .{ "Set-Cookie", cookie };
            break :blk h;
        },
    };
}
```

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

---

## Live Reload

Spider auto-injects WebSocket live reload in development mode:

```zig
// main.zig
pub const spider_config = spider.Config{
    .env = .development, // enables live reload
};
```

When you save a template or static file, the browser refreshes automatically. No configuration needed — just run `zig build run` in dev mode.

---

## Configuration

Create `spider.config.zig` or use `spider_config` in your `main.zig`:

```zig
const spider = @import("spider");

pub const spider_config = spider.Config{
    .views_dir = "./views",
    .layout = "layout",
    .env = .development, // enables live reload
};
```

---



## Project Structure

```
src/
├── core/
│   ├── app.zig          — Server, routing, workers
│   ├── context.zig      — Ctx, Response, ResponseOptions
│   └── database.zig     — Database interface (vtable)
├── routing/
│   ├── router.zig       — Trie router
│   └── group.zig        — Route groups
├── modules/
│   ├── auth/auth.zig    — JWT, cookies, middleware
│   ├── static.zig       — Static file serving
│   ├── dashboard.zig    — Built-in metrics dashboard
│   └── livereload.zig   — Live reload (dev mode)
├── drivers/
│   ├── pg/pg.zig        — PostgreSQL driver (pure Zig wire protocol)
│   ├── sqlite/sqlite.zig— SQLite driver (via libsqlite3)
│   └── mysql/           — MySQL driver (pure Zig wire protocol)
├── render/
│   ├── template.zig     — Template engine (AST parser, components, slots)
│   ├── views.zig        — Template resolver (embed + runtime)
│   └── zmd/             — Markdown support
├── internal/
│   ├── config.zig       — spider.Config
│   ├── env.zig          — .env loader
│   ├── logger.zig       — Structured logging
│   ├── metrics.zig      — Metrics
│   └── buffer_pool.zig  — Buffer pooling
├── ws/
│   ├── websocket.zig    — WebSocket protocol (RFC 6455)
│   └── hub.zig          — Broadcast hub
├── binding/
│   ├── form.zig         — Form data parsing
│   └── form_parser.zig  — Typed form binding
├── providers/
│   └── google.zig       — Google OAuth
└── features/            — Built-in features (demos, examples)
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
| `c.parseForm(T)` | Parse form body into struct |
| `c.setCookie(name, value, opts)` | Build Set-Cookie string |
| `c.withCookie(name, value, opts)` | Build ResponseOptions with cookie |
| `c.isHtmx()` | True if HX-Request header present |
| `c.isBoosted()` | True if HX-Boosted header present |
| `c.arena` | Per-request arena allocator |

### `spider.ResponseOptions`

```zig
pub const ResponseOptions = struct {
    status: std.http.Status = .ok,
    headers: []const [2][]const u8 = &.{},
};
```

### `spider.Server` Methods

| Method | Description |
|--------|-------------|
| `server.get(path, handler)` | Register GET route |
| `server.post(path, handler)` | Register POST route |
| `server.put(path, handler)` | Register PUT route |
| `server.delete(path, handler)` | Register DELETE route |
| `server.use(middleware)` | Global middleware |
| `server.useAt(path, middleware)` | Path-scoped middleware |
| `server.group(prefix, middlewares, fn)` | Route group with middleware |
| `server.onError(handler)` | Global error handler |
| `server.listen(port)` | Start server |

### `spider.pg` Methods (aliased as `const db = spider.pg`)

| Method | Description |
|--------|-------------|
| `db.init(allocator, io, config)` | Initialize pool (DbConfig with optional overrides) |
| `db.deinit()` | Shutdown pool |
| `db.query(T, arena, sql, params)` | Parameterized query → `[]T`, `i32`, or `void` |
| `db.queryOne(T, arena, sql, params)` | Parameterized query → `?T` (single row) |
| `db.queryExecute(T, arena, sql)` | Raw SQL without params |
| `db.queryOneExecute(T, arena, sql)` | Raw SQL single row |
| `db.array(T, values)` | Create array param for `ANY($1)` |
| `db.begin()` | Start transaction → `Transaction` |
| `db.Transaction.query(T, arena, sql, params)` | Query inside transaction |
| `db.Transaction.queryOne(T, arena, sql, params)` | Single row inside transaction |
| `db.Transaction.commit()` | Commit transaction |
| `db.Transaction.rollback()` | Rollback transaction |

---

## Examples

- 🚀 **[SpiderStack](examples/spiderstack/)** — Full-featured starter kit with Google OAuth, PostgreSQL, HTMX, Tailwind, and DaisyUI

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
