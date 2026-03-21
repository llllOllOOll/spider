# <img src="assets/spider_logo.png" width="32" height="32" alt="Spider Logo"> Spider

Spider web framework written in Zig (tested with `0.16.0-dev`).

📖 **Full Documentation:** https://spiderme.org

## Features

* **Authentication System** - JWT, cookies, Google OAuth
* **HTTP Client** - External API requests with HTTPS
* **PostgreSQL Client** - With connection pooling and retry logic
* **Trie-based router** with dynamic params (`/users/:id`)
* **WebSocket support** + hub broadcasting
* **JSON & text responses**
* **Connection & buffer pooling**
* **Structured JSON logging**
* **Metrics + built-in dashboard**
* **Static file serving**
* **Graceful shutdown (SIGINT/SIGTERM)
* **Environment configuration** (.env file support)
* **Template engine** - Embedded HTML templates**

---

## Requirements

* Zig `0.16.0-dev` (or compatible)

```bash
zig version
```

---

## Installation (zig fetch)

```bash
zig fetch --save git+https://github.com/llllOllOOll/spider
```

This will update your `build.zig.zon`:

```zig
.dependencies = .{
    .spider = .{
        .url = "git+https://github.com/llllOllOOll/spider#9e2b0e23b5abec169a24e647ef86d14312802487",
        .hash = "spider-0.3.0-RIctlRG0AQBPowPNb2uPUwmAzLlfKVbjpRT9ZU6NsbNe",
    },
},
```

---

## Configure `build.zig`

```zig
const spider_dep = b.dependency("spider", .{
    .target = target,
});

const exe = b.addExecutable(.{
    .name = "zig_spider",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "spider", .module = spider_dep.module("spider") },
        },
    }),
});
```

---

## Quick Start

**src/main.zig**

```zig
const std = @import("std");
const spider = @import("spider");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Load environment configuration
    spider.loadEnv(allocator, ".env") catch {};

    // Initialize server with optional layout
    const server = try spider.Spider.init(allocator, io, "127.0.0.1", 8080, .{
        .layout = @embedFile("views/layout.html"),
    });
    defer server.deinit();

    try server
        .get("/", pingHandler)
        .get("/api/data", apiHandler)
        .listen();
}

fn pingHandler(alc: std.mem.Allocator, _: *spider.Request) !spider.Response {
    return spider.Response.json(alc, .{ .msg = "pong" });
}

fn apiHandler(alc: std.mem.Allocator, _: *spider.Request) !spider.Response {
    // Example using HTTP client
    const http_client = spider.http_client;
    const response = try http_client.get(
        alc,
        "https://jsonplaceholder.typicode.com/posts/1",
        &.{}
    );
    defer alc.free(response);
    
    return spider.Response.json(alc, .{ .external_data = response });
}
```

---

## Run

```bash
zig build run
```

Open:

```
http://localhost:8080/
```

Response:

```json
{"msg":"pong"}
```

---

## Built-in Dashboard

Spider exposes internal metrics at:

```
http://localhost:8080/_spider/dashboard
```

Includes:

* Request count
* Latency metrics
* Active connections
* Runtime stats

---

## Authentication Example

Spider provides a complete authentication system:

```zig
const auth = spider.auth;

// JWT Token
const token = try auth.jwtSign(allocator, .{
    .sub = user_id,
    .email = user_email,
    .exp = std.time.timestamp() + 3600
}, jwt_secret);

// Cookie Management
const cookie = try auth.cookieSet(allocator, token);
```

## HTTP Client Example

Make external API requests easily:

```zig
const http_client = spider.http_client;

const response = try http_client.get(
    allocator,
    "https://api.example.com/data",
    &.{.{ .name = "Authorization", .value = "Bearer token" }}
);
```

## Form Data

Parse form submissions with support for arrays, dot notation, and URL decoding:

```zig
fn handleForm(alc: std.mem.Allocator, req: *spider.Request) !spider.Response {
    var form = try req.form(alc);
    defer form.deinit();

    // Simple field
    const name = form.get("name");

    // Nested field (dot notation)
    const email = form.get("user.email");

    // Array field (items[]=a&items[]=b)
    const tags = form.getArray("tags");

    return spider.Response.json(alc, .{ .name = name });
}
```

## HTMX-Aware Rendering

`renderView` automatically handles HTMX requests by returning partial content:

```zig
// Full page or partial content — handled automatically
const view = @embedFile("views/dashboard.html");
return spider.renderView(alc, req, view, data);

// For explicit block rendering:
const html = try spider.renderBlock(alc, view, "content", data);
return spider.Response.html(alc, html);
```

With a registered layout, `renderView`:
- Returns full page with layout for normal requests
- Returns only the content block for HTMX requests (when `HX-Request` header is set)

## Environment Configuration

Spider automatically loads `.env` files:

```bash
# .env
POSTGRES_HOST=localhost
POSTGRES_USER=spider
POSTGRES_PASSWORD=secret
```

```zig
// Uses environment variables automatically
spider.loadEnv(allocator, ".env") catch {};
try spider.pg.init(allocator, io, .{});
```

---

## Development

```bash
# Run all tests
zig test .

# Format
zig fmt .
```

---

## Project Structure

| Module                 | Description                    |
| ---------------------- | ------------------------------ |
| `spider.web`           | HTTP primitives                |
| `spider.router`        | Trie router                    |
| `spider.websocket`     | WebSocket protocol             |
| `spider.ws_hub`        | WS broadcasting hub            |
| `spider.pg`            | PostgreSQL client              |
| `spider.logger`        | JSON logger                    |
| `spider.metrics`       | Metrics system                 |
| `spider.auth`          | Authentication system          |
| `spider.http_client`   | External HTTP requests         |
| `spider.google`        | Google OAuth integration       |
| `spider.template`      | Template engine                |
| `spider.form`          | FormData parsing               |

---

## Examples & Resources

* 📖 **Full Documentation**: https://spiderme.org
* 🚀 **Demo Application**: https://spiderme.org (live demo)
* 💬 **WebSocket Chat Demo**: https://spiderme.org/chat
* 📊 **Metrics Dashboard**: https://spiderme.org/_spider/dashboard
* 🔐 **Authentication Examples**: Check the `smoney` project

## License

MIT
