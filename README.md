# 🕷 Spider Web Server

High-performance HTTP server written in Zig 0.16, targeting Bun-level performance.

## 🚀 Performance

| Version | RPS (100c) | RPS (400c) |
|---------|------------|------------|
| **Spider v0.3.0** | 592K | 481K |
| Spider v0.1.0 | 616K | 502K |
| Bun | ~136K | ~100K |
| Go | ~62K | ~50K |

Spider achieves **Bun-level performance** with native Zig.

## ✨ Features

- **Trie-based router** with dynamic params (`/users/:id`, `/posts/:slug`)
- **Dual-path routing**: fast static + dynamic Trie
- **Graceful shutdown** (SIGTERM/SIGINT)
- **Structured logging** (JSON to stderr)
- **/health endpoint** for liveness probes
- **Static file serving** with MIME detection
- **ArenaAllocator** per request (zero allocation)
- **Persistent connections** (Keep-Alive)
- **Security**: Max body size 1MB

## 🏗️ Architecture

```
Spider
├── Io.Group + concurrent (thread pool)
├── Trie Router
│   ├── static_routes: StringHashMap (fast path)
│   └── root: Trie Node (dynamic path)
└── ArenaAllocator per connection + per request
```

## 🚀 Quick Start

```zig
const std = @import("std");
const spider = @import("spider");
const web = spider.web;

fn indexHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    return try web.Response.text(allocator, "Hello from Spider!");
}

fn getUser(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    const id = req.param("id") orelse "unknown";
    const body = try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\"}}", .{id});
    return web.Response.json(allocator, body);
}

pub fn main(init: std.process.Init) !void {
    var app = try spider.Spider.init(init.gpa, init.io, 8080);
    defer app.deinit();

    app.get("/", indexHandler)
        .get("/users/:id", getUser)
        .listen() catch |err| return err;
}
```

### Build & Run

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/spider
```

## 📊 Benchmarks

```
Spider v0.3.0 (100 connections):
  Requests/sec: 592,000
  Latency: 245μs avg

Spider v0.3.0 (400 connections):
  Requests/sec: 481,000  
  Latency: 970μs avg
```

## 🗺️ Roadmap

| Version | Status | Features |
|---------|--------|----------|
| v0.1.0 | ✅ | Baseline 616K RPS |
| v0.2.0 | ✅ | Production ready (shutdown, health, logs, deploy) |
| v0.3.0 | ✅ | Trie router + dynamic params |
| v0.4.0 | 🔜 | Middleware |
| v0.5.0 | 📋 | PostgreSQL |
| v0.6.0 | 📋 | TLS native (BoringSSL) |

## 🌍 Deploy

### nginx (TLS termination)

```bash
# Copy config
sudo cp deploy/nginx.conf /etc/nginx/nginx.conf

# Run spider on localhost:8080
zig build run -Doptimize=ReleaseFast

# nginx handles HTTPS on port 443
```

### Caddy (auto TLS)

```bash
# Run spider
zig build run -Doptimize=ReleaseFast &

# Caddy auto-configures HTTPS
cd deploy && caddy run
```

See `deploy/` for full configuration.

## 📝 License

MIT
