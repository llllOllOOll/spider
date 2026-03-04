# Spider

High-performance HTTP web framework written in Zig.

## Features

- **Trie-based router** with dynamic parameters (`/users/:id`, `/posts/:slug`)
- **Template engine** with variables, loops, conditionals, and includes
- **WebSocket support** with hub management
- **PostgreSQL client** with connection pooling
- **Connection pooling** and buffer pooling for performance
- **Structured logging** (JSON to stderr)
- **Metrics collection**
- **Static file serving** with MIME detection
- **Graceful shutdown** (SIGTERM/SIGINT)

## Installation

```bash
# Add to your build.zig.zon
.{
    .dependencies = .{
        .spider = .{
            .url = "https://github.com/yourorg/spider",
            .version = "0.3.0",
        },
    },
}
```

## Quick Start

```zig
const std = @import("std");
const spider = @import("spider");
const web = spider.web;

fn indexHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    return try web.Response.text(allocator, "Hello from Spider!");
}

pub fn main(init: std.process.Init) !void {
    var app = try spider.Spider.init(init.gpa, init.io, "0.0.0.0", 8080);
    defer app.deinit();

    app.get("/", indexHandler)
        .listen() catch |err| return err;
}
```

## Build

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/spider
```

## Development

```bash
# Run tests
zig test .

# Run a specific test
zig test src/template.zig --test-filter "basic variable"

# Format code
zig fmt .
```

## Modules

| Module | Description |
|--------|-------------|
| `spider.web` | Request/Response types, HTTP utilities |
| `spider.router` | Trie-based routing |
| `spider.template` | Template engine |
| `spider.websocket` | WebSocket protocol |
| `spider.ws_hub` | WebSocket hub for broadcasting |
| `spider.pg` | PostgreSQL client |
| `spider.logger` | Structured JSON logging |
| `spider.metrics` | Request metrics |

## License

MIT
