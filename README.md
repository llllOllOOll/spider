# 🕸️ Spider Web Server

A high-performance HTTP server written in Zig 0.16, targeting Bun-level performance.

## 🚀 Performance

| Metric | Spider | Bun | Go |
|--------|--------|-----|-----|
| **RPS** | ~104K | ~136K | ~62K |
| **Latency (Avg)** | 1.06ms | 0.78ms | 6.41ms |
| **Tail Latency (Max)** | 67ms | 45ms | 299ms |

Spider outperforms Go by **67%** and is closing the gap to Bun.

## 🎯 Features

- **Thread-per-connection** model with proper resource management
- **StringHashMap-based routing** for fast route lookups
- **Static file serving** with MIME type detection
- **Persistent connections** (Keep-Alive) support
- **Security hardening**: Max body size limits (1MB)
- **Memory management**: ArenaAllocator per connection

## 🏗️ Architecture

```
Server (struct)
├── listener (TCP)
├── router (StringHashMap)
└── static_dir (file serving)

handleConnection (per thread)
├── read_buffer / write_buffer
├── http_server
└── arena_allocator (per request)
```

## 🔧 Build

```bash
zig build
```

## 🏃 Run

```bash
zig build run
# or
./zig-out/bin/simple_server
```

## 🧪 Test

```bash
./validate.sh
```

## 🎯 Spider 2.0 Roadmap

### Phase 1: Zero-Copy (Current)
- [x] Thread-per-connection
- [ ] sendfile for static files
- [ ] Buffer pooling

### Phase 2: Event Loop
- [ ] Migrate to `std.Io.Threaded` (io_uring)
- [ ] Single-threaded async architecture
- [ ] Target: Match Bun (136K+ RPS)

### Phase 3: Optimizations
- [ ] Route parameters support
- [ ] WebSocket support
- [ ] HTTP/2 support

## 📊 Benchmarks

### Spider vs Bun
```
Spider: 104,427 RPS
Bun:    135,953 RPS
Gap:    30%
```

### Spider vs Go
```
Spider: 104,427 RPS
Go:      62,418 RPS
Spider:  +67% faster
```

## 📝 License

MIT
