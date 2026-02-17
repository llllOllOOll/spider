# Spider MCP Server

MCP Server providing Spider Web Server development tools and resources for AI coding assistants.

## Features

- **Tools**: zig_build, zig_run, zig_test, zig_fmt
- **Resources**: spider_architecture, spider_routing, spider_security, spider_benchmarks
- **Prompts**: spider_app_mode, spider_core_mode

## Quick Test

```bash
# Test connection
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ./zig-out/bin/spider

# List tools
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | ./zig-out/bin/spider
```

## Running

```bash
zig build
./zig-out/bin/simple_server
```

---

## 📦 Adding Spider to a New Project

### Step 1: Create build.zig.zon

```zig
.{
    .name = "my-app",
    .version = "0.0.1",
    .dependencies = .{
        .spider = .{
            .path = "/path/to/simple_server",
        },
    },
}
```

### Step 2: Configure build.zig

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{ 
        .name = "my-app",
        .target = target,
        .optimize = optimize,
    });

    exe.addModule("spider", b.dependency("spider", .{}).module("spider", null));
    exe.root_source_file = b.path("src/main.zig");

    b.installArtifact(exe);
}
```

### Step 3: Create Your Application

```zig
// src/main.zig
const std = @import("std");
const spider = @import("spider");

const index_html = @embedFile("index.html");

fn helloHandler(req: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
    _ = allocator;
    try req.respond("<h1>Hello from Spider!</h1>", .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html" }},
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const io = std.Io.global_threaded.io();

    var server = try spider.Server.init(allocator, io, 8080, "src/static");
    defer server.deinit();

    // Register routes
    try server.router.put("/hello", helloHandler);

    std.debug.print("Server listening on port 8080\n", .{});
    try server.start();
}
```

### Step 4: Directory Structure

```
my-app/
├── build.zig
├── build.zig.zon
└── src/
    ├── main.zig
    ├── index.html
    └── static/
        └── style.css
```

---

# Spider Web Server - Technical Specification

## Project Identity

**Spider** is a high-performance HTTP server written in Zig 0.16, targeting Bun-level performance.

| Metric | Value |
|--------|-------|
| **RPS** | ~104K |
| **Latency (Avg)** | 1.06ms |
| **Tail Latency (Max)** | 67ms |
| **vs Go** | +67% faster |
| **vs Bun** | -30% gap |

---

## Dual-Context Definition

### 🔧 Application Mode (Backend Use)

For developers using Spider as a server to build AHA Stack applications.

#### Route Registration (HashMap)

```zig
// In Server.init(), routes are registered in the HashMap:
try self.router.put("/", indexHandler);
try self.router.put("/metric", metricHandler);
```

**Handler Signature:**
```zig
const HandlerFn = *const fn (req: *std.http.Server.Request, allocator: std.mem.Allocator) anyerror!void;
```

#### ArenaAllocator Usage

Each request gets a fresh allocator from the ArenaAllocator:

```zig
var arena_allocator = std.heap.ArenaAllocator.init(ctx.allocator);
defer arena_allocator.deinit();

while (true) {
    _ = arena_allocator.reset(.free_all);  // Reset between requests
    
    const arena = arena_allocator.allocator();
    // Use arena for any allocations in handlers
}
```

#### AHA Stack - HTML Fragments

Return HTML fragments for Alpine.js interactivity:

```zig
fn metricHandler(req: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
    try req.respond(
        "<div x-data=\"{ count: 0 }\">" ++
        "  <button @click=\"count++\">Increment</button>" ++
        "  <span x-text=\"count\"></span>" ++
        "</div>",
        .{
            .status = .ok,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html" }},
        }
    );
}
```

---

### ⚙️ Core Mode (Server Dev)

For developers modifying the Spider engine itself.

#### Thread-per-Connection Architecture

```zig
// Main loop accepts connections and spawns a thread for each:
while (true) {
    const stream = self.listener.accept(self.io) catch continue;
    
    const ctx = try self.allocator.create(ConnectionContext);
    ctx.* = .{ .stream = stream, .io = self.io, ... };
    
    _ = Thread.spawn(.{}, handleConnection, .{ctx}) catch {
        // Handle error
    };
}
```

#### Static File Handler

```zig
fn staticFileHandler(req: *std.http.Server.Request, allocator: std.mem.Allocator, static_dir: []const u8, io: Io) !void {
    const path = req.head.target;
    
    // Security: prevent directory traversal
    if (std.mem.indexOf(u8, path, "..") != null) {
        try notFoundHandler(req, allocator);
        return;
    }
    
    const full_path = try std.fs.path.join(allocator, &.{ static_dir, path });
    defer allocator.free(full_path);
    
    const file_content = std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .unlimited) catch {
        try notFoundHandler(req, allocator);
        return;
    };
    defer allocator.free(file_content);
    
    const content_type = getMimeType(full_path);
    try req.respond(file_content, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = content_type }},
    });
}
```

#### Zig 0.16-dev Constraints

**Important API Changes:**
- Networking is in `std.Io.net` (not `std.net`)
- Use `std.Io.global_threaded` for event-driven I/O
- HTTP Server uses `std.http.Server` with reader/writer interface

**Key Patterns:**
```zig
// Creating a server (Zig 0.16)
const address = net.IpAddress{ .ip4 = net.Ip4Address.loopback(port) };
var listener = try net.IpAddress.listen(address, io, .{});

// Accepting connections
const stream = listener.accept(io) catch {};

// HTTP Server setup
var stream_reader = net.Stream.Reader.init(stream, io, &read_buffer);
var stream_writer = net.Stream.Writer.init(stream, io, &write_buffer);
var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
```

---

## Project File Structure

```
simple_server/
├── src/
│   ├── main.zig          # Entry point: calls server.start()
│   ├── server.zig        # Main server implementation
│   ├── root.zig          # Package root
│   ├── index.html       # Embedded HTML (@embedFile)
│   └── static/          # Static files directory
│       ├── style.css
│       └── app.js
├── build.zig            # Build configuration
├── build.zig.zon        # Package manifest
├── README.md            # Project documentation
└── SPIDER_2.0_BLUEPRINT.md  # Performance roadmap
```

---

## Performance Constraints

### 104K RPS Benchmark

- **Test Configuration**: wrk -t12 -c400 -d30s
- **Response**: Simple HTML string

### No GC Stability Rules

Spider achieves stable tail latency (67ms max) because:

1. **No Garbage Collector**: Zig uses manual memory management
2. **Stack Allocation**: Most data stays on stack
3. **ArenaAllocator**: Per-request memory is reset, not collected
4. **Thread Isolation**: Each connection has dedicated thread, no GC pauses

**Latency Comparison:**
| Server | Avg Latency | Max Latency |
|--------|-------------|-------------|
| Spider (Zig) | 1.06ms | 67ms |
| Bun | 0.78ms | 45ms |
| Go | 6.41ms | 299ms |

---

## Security Features

### Payload Size Limit

```zig
const MAX_BODY_SIZE: u64 = 1 * 1024 * 1024; // 1MB

// In request handling:
if (request.head.content_length) |len| {
    if (len > MAX_BODY_SIZE) {
        // Return 413 Payload Too Large
        break;
    }
}
```

### Path Traversal Protection

Static file handler checks for `..` in paths:
```zig
if (std.mem.indexOf(u8, path, "..") != null) {
    try notFoundHandler(req, allocator);
    return;
}
```

---

## Development Commands

```bash
# Build
zig build

# Run server
zig build run
# or
./zig-out/bin/simple_server

# Run tests
zig test

# Format code
zig fmt src/
```
