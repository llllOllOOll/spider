# 🕸️ Spider 2.0 Blueprint - Bridging the Gap to Bun

## Executive Summary

Current Spider: **104K RPS**  
Bun: **136K RPS**  
Gap: **30%**

This document outlines the architectural changes to close this gap.

---

## 🎯 Option 1: Single-Threaded Event Loop (HIGHEST IMPACT)

### The Change
Replace `Thread.spawn()` per connection with `std.Io.Threaded` (async/await using io_uring).

### Expected Impact
| Metric | Current | After | Improvement |
|--------|---------|-------|-------------|
| RPS | 104K | ~130K+ | **+25-30%** |
| Context Switches | 400+ | 1 | Massive reduction |
| Memory/Connection | ~2MB | ~4KB | **-99.8%** |

### Why This Works
- **io_uring**: Linux's high-performance async I/O syscall (supported natively in Zig 0.16)
- **Single thread**: Handles thousands of connections without thread overhead
- **Event-driven**: Like Bun's architecture

### Code Pattern (Zig 0.16)
```zig
var threaded = std.Io.Threaded.init_single_threaded;
const io = threaded.io();

while (true) {
    const stream = try listener.accept(io);
    
    // Async handlers - no threads!
    var request = http_server.receiveHead() catch break;
    try handleRequest(request, arena);
    
    if (!request.head.keep_alive) break;
}
```

### Complexity: **MEDIUM** - Requires refactoring handlers to async

---

## 🎯 Option 2: Thread Pool (QUICK WIN)

### The Change
Replace `Thread.spawn()` with a fixed pool of N workers (where N = CPU cores).

### Expected Impact
| Metric | Current | After | Improvement |
|--------|---------|-------|-------------|
| RPS | 104K | ~115K | **+10-15%** |
| Thread Count | 400+ | 8-16 | **-95%** |

### Why This Works
- Reduces context switching overhead dramatically
- Fixed memory footprint regardless of connections
- Simpler than full async refactor

### Complexity: **LOW** - Drop-in replacement for thread spawn

---

## 🎯 Option 3: Zero-Copy Sendfile (STATIC FILES)

### The Change
Use `std.os.sendfile()` for static file serving instead of reading into buffer.

### Expected Impact
| Metric | Current | After | Improvement |
|--------|---------|-------|-------------|
| Static File RPS | ~50K | ~200K | **+300%** |

### Why This Works
- **sendfile()**: Kernel-level transfer, data never touches userspace
- File descriptor → Socket, zero copies
- Already in Zig stdlib!

### Current vs Zero-Copy
```zig
// CURRENT: User space copies
const file_content = try file.readAllAlloc(io, allocator, stat.size);
try req.respond(file_content, ...);

// ZERO-COPY: Kernel space only
try req.respondStreaming(buffer, .{
    .content_length = stat.size,
    // std.http uses sendfile internally!
});
```

### Complexity: **LOW** - Already supported by std.http

---

## 📊 Impact Analysis

| Option | RPS Gain | Effort | Risk | Recommendation |
|--------|-----------|--------|------|----------------|
| Event Loop | +30% | Medium | Medium | **GO FOR IT** |
| Thread Pool | +15% | Low | Low | Quick win |
| Zero-Copy | +300% (static) | Low | Low | Do anyway |

---

## 🏆 The Winner: Event Loop Architecture

The single most impactful change is moving to `std.Io.Threaded`:

```zig
// Spider 2.0 - Event-Driven Architecture
pub fn main() !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    
    var listener = try net.IpAddress.listen(addr, io, .{});
    
    while (true) {
        // Accept without spawning thread
        const stream = listener.accept(io) catch continue;
        
        // Handle in same thread - async!
        spawn handleConnection(stream, io, arena);
    }
}
```

### Expected Result
- **Before**: 104K RPS (400 threads)
- **After**: ~135K RPS (1 thread, async I/O)
- **Gap**: CLOSED ✅

---

## 🔬 Technical Notes

### Why Bun is Fast
1. Event loop (no thread overhead)
2. sendfile for static files
3. Optimized HTTP parser
4. JIT compilation for hot paths

### Why Spider Can Match
1. Zig is compiled, not interpreted
2. io_uring is faster than epoll (what Node uses)
3. Manual memory = no GC pauses
4. Same sendfile syscall available

### The Gap is NOT Fundamental
Spider can match or exceed Bun because:
- Same Linux kernel (sendfile, io_uring)
- Same TCP stack
- Compiled language (Zig) vs JIT (Bun)

The difference is purely architectural, not fundamental.
