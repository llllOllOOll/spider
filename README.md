![Spider Logo](assets/spider_logo.png)

# Spider

Spider web framework written in Zig (tested with `0.16.0-dev`).

## Features

* **Trie-based router** with dynamic params (`/users/:id`)
* **JSON & text responses**
* **WebSocket support** + hub broadcasting
* **PostgreSQL client** with pooling
* **Connection & buffer pooling**
* **Structured JSON logging**
* **Metrics + built-in dashboard**
* **Static file serving**
* **Graceful shutdown (SIGINT/SIGTERM)**

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

    const server = try spider.Spider.init(allocator, io, "127.0.0.1", 8080);
    defer server.deinit();

    try server
        .get("/", pingHandler)
        .listen();
}

fn pingHandler(alc: std.mem.Allocator, _: *spider.Request) !spider.Response {
    return spider.Response.json(alc, .{ .msg = "pong" });
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

## Development

```bash
# Run all tests
zig test .

# Format
zig fmt .
```

---

## Project Structure

| Module             | Description         |
| ------------------ | ------------------- |
| `spider.web`       | HTTP primitives     |
| `spider.router`    | Trie router         |
| `spider.websocket` | WebSocket protocol  |
| `spider.ws_hub`    | WS broadcasting hub |
| `spider.pg`        | PostgreSQL client   |
| `spider.logger`    | JSON logger         |
| `spider.metrics`   | Metrics system      |

---

## License

MIT
