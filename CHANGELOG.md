# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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