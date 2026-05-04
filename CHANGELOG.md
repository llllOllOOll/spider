# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Live reload — WebSocket auto-inject in dev mode
- Runtime mode fully working — includes, layout, HTMX identical to embed mode
- Auto-detect markdown via `--doc` signature in `c.view()`
- Template AST parser rewrite with component support (PascalCase lookup)
- Named slots (`slot_header`, `slot_sidebar`, etc.) and context clone
- Interpolate slot content from parent context
- Struct object support in for loops with dot notation
- Support newlines in component props, `evalBool` for strings
- `array()` helper function for PostgreSQL `ANY()` optimization
- `else if` support in conditionals
- Comparison operators (`==`, `!=`, `<`, `<=`, `>`, `>=`) in templates
- Coalescing operator (`??`) in templates
- Support string slice iteration and dot notation in `evalBool`
- `c.render()` method to render template string directly

### Fixed
- WebSocket RFC 6455 compliance — `std.Io`, endianness, ping/pong, close handshake, hub broadcast
- Skip script tags in templates, support quoted strings in conditionals, handle nested structs
- Support int/float types, literal props, nested components, and parsed slot
- Parse if/for blocks in `parseTextNodes` and support dot notation in `evalBool`
- Prevent `extends` from leaking into rendered output
- `generate_templates` use parent dir inside views/ for field name prefix
- Silence `ReadFailed` logs, use `std.log` for middleware
- Remove `extends` handling from `view()` — engine handles it internally

### Changed
- **BREAKING**: PostgreSQL driver rewritten — pure Zig wire protocol (no libpq dependency)
- Reorganize PostgreSQL driver structure
- Remove legacy Spider files — `pipeline.zig`, `server.zig`, `web.zig`, stubs

### Removed
- `libpq` dependency (PostgreSQL driver is now pure Zig)
- Legacy `src/web.zig`, `src/core/pipeline.zig`

## [0.1.0] - 2026-04-24

### Added
- HTTP server with graceful shutdown (SIGINT/SIGTERM)
- Trie-based router with dynamic params (`/users/:id`), wildcards
- Template engine with blocks, variables, loops, conditionals, includes
- HTMX-aware rendering (partial content for HX-Request)
- WebSocket support + hub broadcasting
- PostgreSQL client with struct mapping, connection pooling, retry logic
- Authentication system (JWT, cookies, Google OAuth)
- HTTP client for external HTTPS API requests
- FormData parsing (arrays, dot notation, URL decoding)
- Structured JSON logging
- Metrics collection with built-in dashboard
- Connection & buffer pooling
- Middleware system (chain functions via `server.use(fn)`)
- Static file serving
- Environment configuration (.env file support)
- Group routes (`.groupGet` / `.group` for route prefixes)
- Docker support with official Zig image
- Zig 0.16+ compatibility
