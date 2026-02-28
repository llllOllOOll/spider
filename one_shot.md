# One-Shot Implementation Guide for Max (Spider / Zig 0.16)

> **Purpose:** This guide ensures Max can implement features in Spider in a single shot — no mid-way refactoring, no wrong API calls, no compile errors.
> **Zig Version:** `0.16.0-dev.2565+684032671`

---

## 1. Pre-Implementation Checklist

Before writing a single line of code, always verify these points directly in the Spider source:

| Check | Question | Why it matters |
|-------|----------|----------------|
| Request context | Does `web.Request` expose what you need? (IP, headers, body, params) | Avoid assuming fields exist |
| Response context | Does `web.Response` have body length, status, content-type? | Needed for bytes_out, redirects |
| Connection lifecycle | Where in `server.zig` is the best hook point? | Instrumentation without breaking flow |
| WebSocket | Does `ws_hub` expose `count()` or equivalent? | Don't assume WS API |
| `io` availability | Is `std.Io` (or `Io`) accessible where you need it? | Required for Clock, sleep, net |
| Circular deps | Will your new file import from `web.zig` which also imports it? | Fatal compile error |

**Rule:** Read the source first. Never assume — always verify with a direct file read.

---

## 2. Zig 0.16 API Reference (Verified)

### 2.1 Time — `std.Io.Clock` ✅

> ⛔ `std.time.timestamp()` — **DOES NOT EXIST in Zig 0.16. Do not use.**
> ⛔ `std.time.Timer` — superseded by `std.Io.Clock`.

```zig
// Capture start time (use .awake for server uptime — monotonic, excludes suspend)
const start_time = std.Io.Clock.now(.awake, io);

// Calculate elapsed seconds
const now = std.Io.Clock.now(.awake, io);
const uptime_seconds = start_time.durationTo(now).toSeconds(); // returns i64
```

**Clock types:**

| Clock | Use Case |
|-------|----------|
| `.real` | Wall clock (Unix epoch, affected by NTP) |
| `.awake` | Monotonic, excludes suspend — **recommended for uptime** |
| `.boot` | Monotonic, includes suspend time |
| `.cpu_process` | CPU time for process |
| `.cpu_thread` | CPU time for thread |

**Key types:**
- `std.Io.Timestamp` — `.toSeconds() i64`, `.toMilliseconds() i64`, `.toNanoseconds() i96`, `.durationTo(other) Duration`
- `std.Io.Duration` — `.fromSeconds(i64)`, `.fromMilliseconds(i64)`, `.fromNanoseconds(i64)`
- `std.Io.sleep(io, duration, clock)` — recommended sleep

---

### 2.2 Atomic Counters — `std.atomic.Value(T)` ✅

```zig
var counter = std.atomic.Value(u64).init(0);

_ = counter.fetchAdd(1, .monotonic);   // increment, returns old value
_ = counter.fetchSub(1, .monotonic);   // decrement
const val = counter.load(.acquire);    // read
counter.store(new_val, .release);      // write
```

**Valid memory orderings:** `.monotonic`, `.acquire`, `.release`, `.seq_cst`, `.acq_rel`

**Pattern for global metrics with io:**
```zig
// metrics.zig - store io globally for Clock.now()
var global_io: std.Io = undefined;
pub var global_metrics: Metrics = undefined;
var server_start_time: std.Io.Timestamp = undefined;

pub fn initMetrics(io: std.Io) void {
    global_io = io;
    global_metrics = Metrics.init();
    server_start_time = std.Io.Clock.now(.awake, io);
}
```

---

### 2.3 ArrayList — `std.ArrayList(T)` ✅

```zig
// Initialization (Zig 0.16: use .empty, not .init)
var list = std.ArrayList(u8).empty;

// Operations — always pass allocator explicitly
try list.append(allocator, value);
try list.appendSlice(allocator, slice);
const owned = try list.toOwnedSlice(allocator);

// Cleanup
list.deinit(allocator);
```

> ⛔ `std.ArrayList(T).init(allocator)` — **old API, do not use.**

---

### 2.4 JSON — `std.json.stringifyAlloc` ✅

```zig
// Serialize struct to []u8 (caller must free)
const json_str = try std.json.stringifyAlloc(allocator, my_struct, .{});
defer allocator.free(json_str);
```

Note: `web.Response.json()` already wraps this in Spider — use it directly when possible.

---

### 2.5 Embed Files — `@embedFile` ✅

```zig
const dashboard_html = @embedFile("dashboard.html");
```

Unchanged from previous Zig versions. Path is relative to the source file.

---

### 2.6 `std.io` ✅

No breaking changes relevant to Spider's use. Writer/reader interfaces are stable.

---

## 3. Spider-Specific Patterns (Verified)

### 3.1 `web.Request` — available fields
`method`, `path`, `query`, `headers`, `body`, `params`

> ⚠️ **Does NOT expose client IP or socket.** If you need the peer address, it must be passed via `ConnectionContext` — captured at `accept()` in `server.zig`.

### 3.2 `web.Response` — available fields
Has `body: ?[]const u8` → use `body.len` for `bytes_out` counting (approximate, excludes headers).

`web.Response.json(allocator, struct)` — exists and works. Use it for JSON endpoints.

### 3.3 Route registration — `web.zig App.init`
Internal routes are registered automatically in `App.init`. No user action required:
```zig
try app.router.add(.get, "/_spider/metrics", dashboard.metricsHandler);
try app.router.add(.get, "/_spider/dashboard", dashboard.dashboardHandler);
```

### 3.4 WebSocket client count
`ws_hub.count()` exists at `ws_hub.zig:45-49`. Use directly.

### 3.5 `io` availability in `server.zig`
```zig
// Line 6:  const Io = std.Io;
// Line 52: io: Io  (in Server struct)
// Line 60: pub fn init(allocator, io: Io, ...)
// Line 69: self.io = io
```

**Two approaches for global functions needing io:**

1. **Pass io to init (recommended):** Call `initMetrics(self.io)` at server startup
2. **Store globally:** Use `var global_io: std.Io = undefined` pattern shown above

### 3.6 Spider Fluent API
```zig
app.get("/", indexHandler)
    .get("/api/users", listUsers)
    .post("/api/users", createUser)
    .use(corsMiddleware);
```

### 3.7 Route Groups
```zig
app.groupGet("/api/v1", "/users", usersHandler)
    .groupPost("/api/v1", "/users", createUserHandler)
    .groupGet("/api/v1", "/tasks", tasksHandler);
```

### 3.8 Template Rendering
```zig
const html = try template.render(allocator, "page.html", .{ .title = "Hello", .user = user });
return try web.Response.html(allocator, html);
```

### 3.9 Auto-register internal routes in App.init
```zig
pub fn init(allocator: std.mem.Allocator) !*App {
    // ... existing init code ...
    try app.registerInternalRoutes();
    return app;
}

fn registerInternalRoutes(self: *App) !void {
    try self.router.add(.get, "/_spider/metrics", dashboard.metricsHandler);
    // ...
}
```

---

## 4. Communication Protocol with Max

The workflow that produced a clean single-shot build:

```
1. Read Spider source → verify what exists (don't assume)
2. Consult zig-mcp → verify APIs for Zig 0.16-dev specifically
3. Flag all uncertainties BEFORE coding
4. Get decisions on all open questions
5. Implement everything in one shot
6. zig build → report full output
```

**When to stop and ask:**
- Any field or method you can't confirm exists in source
- Any API you're not 100% sure about for Zig 0.16
- Architectural decision with tradeoffs (e.g., IP check approach)

---

## 5. Case Study — Spider Dashboard (Reference Implementation)

**Implemented in a single shot. Zero compile errors.**

### Files created/modified:
| File | Role |
|------|------|
| `src/metrics.zig` | Global atomic counters + uptime via `std.Io.Clock` |
| `src/dashboard.zig` | Handlers with route registration |
| `src/dashboard.html` | HTMX UI, embedded via `@embedFile` |
| `src/web.zig` | Auto-register `/_spider/*` routes in `App.init` |
| `src/server.zig` | Instrumentation hooks |

### Metrics exposed:
```json
GET /_spider/metrics
{
  "uptime": 3600,
  "total_requests": 123456,
  "bytes_in": 1048576,
  "bytes_out": 2097152,
  "errors": 12,
  "slow_requests": 5,
  "ws_clients": 5
}
```

### Key decisions made:
| Decision | Choice | Rationale |
|----------|--------|-----------|
| IP auth | Skipped for MVP | `web.Request` doesn't expose IP; add via `ConnectionContext` later |
| Time API | `std.Io.Clock.now(.awake, io)` | Correct Zig 0.16 API; monotonic; `io` confirmed available |
| Persistence | None (in-memory only) | Metrics are ephemeral; no DB overhead |
| HTMX | `@embedFile` (no CDN) | Offline-first; consistent with Spider philosophy |
| Bytes counting | `content_length` + `body.len` | Approximate but sufficient for dashboard |
| Slow requests | Counter >500ms | Cheaper than p95; still actionable |

### Issues caught BEFORE implementation:
- `std.time.timestamp()` doesn't exist → replaced with `std.Io.Clock`
- `web.Request` has no IP field → IP check deferred
- `std.ArrayList.init()` is old API → use `.empty`
- `@intCast` on `i64` uptime → eliminated by using `Duration.toSeconds()`

---

## 6. DO NOT USE — Deprecated / Non-existent APIs

| API | Status | Use Instead |
|-----|--------|-------------|
| `std.time.timestamp()` | ❌ Does not exist in 0.16 | `std.Io.Clock.now(.real, io).toSeconds()` |
| `std.time.milliTimestamp()` | ❌ Does not exist in 0.16 | `std.Io.Clock.now(.real, io).toMilliseconds()` |
| `std.time.Timer.start()` | ❌ Superseded | `std.Io.Clock.now(.awake, io)` |
| `std.ArrayList(T).init(alloc)` | ❌ Old API | `std.ArrayList(T).empty` |
| `X-Forwarded-For` for IP check | ⚠️ Proxy-only | Socket-level via `ConnectionContext` |

---


