# Spider Project Chat Context

## Project Location
`/home/seven/repos/zig/web/spider`

## Current State (Feb 18, 2026)

### Project Structure
- **src/main.zig** - Entry point, calls server.start()
- **src/server.zig** - Main HTTP server (197 lines)
  - Thread-per-connection concurrency
  - Routes: `/`, `/metric`
  - Static file serving from `src/static/`
  - Arena allocator per connection
- **build.zig** - Build configuration
- **src/root.zig** - Package root (exports add function)

### Benchmark Results
```
zig build -Doptimize=ReleaseFast
./zig-out/bin/spider &
wrk -t4 -c100 -d10s http://localhost:8080/
```
**Result: 616,877 RPS** (617K requests/second)

### Allocator Usage in server.zig

Line 193 - Allocator source:
```zig
var server = try Server.init(init.arena.allocator(), init.io, 8080, "src/static");
```

`init.arena.allocator()` comes from `std.process.Init`:
- `arena`: *std.heap.ArenaAllocator - permanent storage for process
- `gpa`: Allocator - general purpose allocator, threadsafe
- `io`: Io - default I/O implementation

These are initialized by Zig runtime before main() is called.

### Key Lines in server.zig
- Line 13, 23: `allocator: std.mem.Allocator` in structs
- Line 89-93: Per-request arena allocator:
  ```zig
  var arena_allocator = std.heap.ArenaAllocator.init(ctx.allocator);
  defer arena_allocator.deinit();
  _ = arena_allocator.reset(.free_all);
  ```
- Line 106: `const arena = arena_allocator.allocator();`

### HTTP Library Reference (/home/seven/repos/zig/web/http.zig)
- Uses ArenaAllocator for server-level allocations
- Uses req_arena for per-request allocations
- Uses GeneralPurposeAllocator only in tests
