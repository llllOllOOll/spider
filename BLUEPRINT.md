# Spider Blueprint

## Status
Version: 0.1.0
Performance: 617K RPS (ReleaseFast)
Zig: 0.16.0-dev.2565

## Architecture
- Thread-per-connection (Thread.spawn)
- std.Io.net for networking
- std.http.Server for HTTP parsing
- Arena allocator per connection
- Routes: StringHashMap

## Current Structure
src/
├── main.zig      ← entry point (std.process.Init)
├── server.zig    ← HTTP server + router
├── index.html    ← embedded at compile time
└── static/       ← static file serving

## Roadmap
- [ ] Fluent API (DX): app.get("/", handler).listen()
- [ ] Spider as importable module
- [ ] Thread pool (replace thread-per-connection)
- [ ] Custom HTTP parser (replace std.http.Server)
- [ ] PostgreSQL integration
