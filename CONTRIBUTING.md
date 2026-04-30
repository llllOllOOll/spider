# Contributing to Spider

Spider is built and maintained by **Seven** on **Arch Linux**. All development, testing, and CI happens on Linux. This means Spider works great on Linux — but **Windows and macOS support is untested and needs contributors**.

If you're on Windows or macOS and want to make Spider work on your platform, that contribution is extremely welcome. See [Platform Support](#platform-support) below.

---

## Table of Contents

- [Architecture](#architecture)
- [Memory Model](#memory-model)
- [Key Design Decisions](#key-design-decisions)
- [Project Structure](#project-structure)
- [Development Setup](#development-setup)
- [Running Tests](#running-tests)
- [Platform Support](#platform-support)
- [Submitting a PR](#submitting-a-pr)
- [Known TODOs](#known-todos)

---

## Architecture

Spider is organized in clear layers. Each layer has a single responsibility and depends only on layers below it.

```
┌─────────────────────────────────────────┐
│           Dev Application               │
│   main.zig — handlers, routes, config   │
└──────────────────┬──────────────────────┘
                   │
┌──────────────────▼──────────────────────┐
│              spider.zig                  │
│         Public API re-exports            │
└──────────────────┬──────────────────────┘
                   │
┌──────────────────▼──────────────────────┐
│           src/core/                      │
│  app.zig       — Server, workers         │
│  context.zig   — Ctx, Response           │
│  pipeline.zig  — HTTP connection loop    │
│  database.zig  — Database vtable         │
└──────────────────┬──────────────────────┘
                   │
        ┌──────────┼──────────┐
        │          │          │
┌───────▼──┐ ┌─────▼────┐ ┌──▼───────────┐
│ routing/ │ │ modules/ │ │   drivers/   │
│ router   │ │ auth     │ │ pg/sqlite/   │
│ trie     │ │ static   │ │ mysql        │
└──────────┘ └──────────┘ └──────────────┘
                   │
        ┌──────────┼──────────┐
        │          │          │
┌───────▼──┐ ┌─────▼────┐ ┌──▼───────────┐
│ render/  │ │internal/ │ │ providers/   │
│ template │ │ env      │ │ google oauth │
│ views    │ │ config   │ │              │
└──────────┘ │ logger   │ └──────────────┘
             │ metrics  │
             └──────────┘
```

### Request lifecycle

```
TCP connection accepted by worker
    → conn_arena created (lives entire connection)
        → req_arena created (reset each request)
            → headers copied to Ctx._headers map
            → body read into Ctx.body
            → router.match() → finds handler + params
            → middleware chain runs (threadlocal, safe with Io.Threaded)
            → handler(c) → returns Response
            → request.respond() sends bytes to socket
        → req_arena.reset() — everything freed
    → keep-alive loop until client closes
→ conn_arena.deinit()
```

---

## Memory Model

Understanding Spider's memory hierarchy is essential for contributing.

```
page_allocator (OS)
│
├── Spider Arena (lives the entire process)
│   ├── route table
│   ├── server config
│   └── startup strings
│
└── smp_allocator (thread-safe, no state — used for workers)
        └── ArenaAllocator per connection (conn_arena)
                └── ArenaAllocator per request (req_arena)
                        └── c.arena ← what the dev sees
```

### Rules

- **`c.arena`** — allocate freely in handlers. Spider resets it after each request. Never store pointers to `c.arena` data beyond the request lifetime.
- **`smp_allocator`** — used for worker threads, connection pools, and anything that lives longer than a request. Thread-safe, no overhead.
- **`Spider Arena`** — routes, config, strings registered at startup. Lives until `server.deinit()`.
- **Never use `page_allocator` directly** in hot paths — it maps full OS pages. Only use it at startup for long-lived allocations.

### Why not `DebugAllocator` for workers?

`DebugAllocator` has internal state. When `Server.init()` returns, the struct is copied to the caller's stack — the internal pointer becomes dangling. `smp_allocator` has no state of its own, so it's safe to copy. This was a real bug we fixed — don't reintroduce it.

---

## Key Design Decisions

These decisions were made deliberately. Before changing them, understand why they exist.

### `threadlocal` for middleware chain

The middleware chain state (`chain_middlewares`, `chain_handler`) is stored in `threadlocal` variables. This is safe because `Io.Threaded` uses OS threads that block — each `handleConnection` runs on its own OS thread from start to finish. There is no coroutine/fiber interleaving within a single thread.

**If Spider ever migrates to `Io.Evented` (io_uring with fibers), this must change.** The fix is to store chain state in `Ctx._chain` instead of `threadlocal`. The code comment marks this explicitly.

### `@import("root")` + `@hasDecl` for embed templates

Libraries in Zig cannot access modules registered in the executable's build system. The only reliable way for Spider (a library) to detect if the dev registered `spider_templates` is via `@import("root")` + `@hasDecl` — the same pattern the Zig stdlib uses for `std_options`.

We tried `addOptions()` with a build flag — it doesn't work because options are module-scoped, not shared between library and executable.

We proved this with a standalone POC in `seven/` before applying to Spider.

### Database vtable

The `Database` interface uses a vtable (pointer + function table) identical to `std.mem.Allocator`. This allows Spider to support PostgreSQL, SQLite, MySQL, and future drivers without the core knowing about any specific driver.

The `query()` method cannot go in the vtable because it has a `comptime T` parameter — Zig vtables don't support comptime generics. Instead, `DatabaseCtx.query()` calls the driver directly via `@ptrCast`. This is a known limitation documented in `src/core/database.zig`.

### Headers copied before body read

`std.http.Server.Request.iterateHeaders()` fails with an assert if called after the body has been read — the request state changes from `.received_head` to something else. Spider copies all headers into `Ctx._headers` (a `StringHashMapUnmanaged`) before reading the body. `c.header()` reads from this map, never from the request directly.

Don't call `request.iterateHeaders()` anywhere except in `handleConnection()` during Ctx initialization.

### `Response` is a value type

Handlers return `!spider.Response` — a value, not a pointer. This follows the Axum/Remix pattern and ensures the compiler catches handlers that forget to return a response. The framework sends the response after the handler returns. This enables middleware to inspect and modify responses.

### Template embed detection

The dev declares `pub const spider_templates = ...` in their `main.zig`. Spider detects this at compile time via:

```zig
const root = @import("root");
const has_embed = @hasDecl(root, "spider_templates");
```

This is identical to how `std_options` works in the Zig stdlib. No build system magic required. Proven in `seven/main_compare.zig` — embed and runtime produce byte-identical output.

### `generate-templates` artifact

Spider exposes a `generate-templates` executable that scans `src/` recursively for `.html` and `.md` files and generates `embedded_templates.zig`. The dev adds it to their `build.zig` as a build step dependency. It runs automatically on every `zig build`.

The field name normalization algorithm: strip extension, replace `/` and `-` with `_`. So `features/auth/views/login.html` → `auth_login`. The `c.view("auth/login")` lookup uses the same normalization — they must stay in sync.

---

## Project Structure

```
spider/
├── src/
│   ├── spider.zig              — public API, all re-exports
│   ├── core/
│   │   ├── app.zig             — Server struct, workers, listen()
│   │   ├── context.zig         — Ctx, Response, ResponseOptions
│   │   ├── pipeline.zig        — handleConnection, HTTP loop
│   │   └── database.zig        — Database vtable + DatabaseCtx
│   ├── routing/
│   │   ├── router.zig          — trie router (new, no web.zig dep)
│   │   ├── group.zig           — route groups
│   ├── modules/
│   │   ├── auth/auth.zig       — JWT, HMAC-SHA256, cookies, middleware
│   │   ├── static.zig          — static file serving from ./public/
│   │   └── dashboard.zig       — built-in metrics dashboard
│   ├── drivers/
│   │   ├── pg/                 — PostgreSQL, pure Zig wire protocol
│   │   │   ├── pg.zig
│   │   │   └── pool.zig
│   │   ├── sqlite/             — SQLite via libsqlite3 C FFI
│   │   ├── mysql/              — MySQL, pure Zig wire protocol
│   │   │   ├── mysql.zig
│   │   │   ├── connection.zig
│   │   │   ├── protocol.zig
│   │   │   └── types.zig
│   │   └── odbc/               — future: multi-db via unixODBC
│   ├── render/
│   │   ├── template.zig        — template engine (83+ tests)
│   │   ├── views.zig           — template index, disk scan
│   │   └── zmd/                — Markdown support
│   ├── internal/
│   │   ├── config.zig          — spider.Config, Env enum
│   │   ├── env.zig             — .env loader, autoLoad, priority
│   │   ├── logger.zig          — structured JSON logging
│   │   ├── metrics.zig         — request metrics
│   │   └── buffer_pool.zig     — buffer pooling
│   ├── ws/
│   │   ├── websocket.zig       — WebSocket protocol
│   │   └── hub.zig             — broadcast hub
│   ├── binding/
│   │   ├── form.zig            — form data parsing
│   │   └── form_parser.zig     — typed form binding
│   ├── providers/
│   │   └── google.zig          — Google OAuth via pacman HTTP client
│   ├── generate_templates.zig  — CLI tool: scans src/, generates embed file
│   ├── web.zig                 — Spider antigo (legacy, não remover ainda)
│   └── main.zig                — Spider's own test server
├── seven/                      — isolated POCs and experiments
│   ├── src/
│   │   ├── main_embed.zig      — embed mode POC
│   │   ├── main_runtime.zig    — runtime mode POC
│   │   ├── main_compare.zig    — proves embed == runtime byte-for-byte
│   │   └── lib.zig             — simulates Spider internals
│   └── build.zig
├── examples/
│   └── spiderstack/            — full production starter kit
│       ├── src/
│       │   ├── main.zig
│       │   ├── features/       — auth, games, movies, todo, home
│       │   └── core/           — middleware, i18n, db migrations
│       └── build.zig
├── includes/                   — C headers for FFI
│   ├── pg.h
│   ├── sqlite.h
│   └── env.h
└── build.zig
```

---

## Development Setup

### Requirements

- Zig `0.17.0-dev` (master branch)
- PostgreSQL (for pg driver tests)
- SQLite3 (system library)
- libpq (PostgreSQL C client)

### Arch Linux (primary platform)

```bash
# Dependencies
sudo pacman -S postgresql sqlite libpq

# Clone
git clone https://github.com/llllOllOOll/spider
cd spider

# Build
zig build

# Run Spider's own test server
zig build run
curl http://localhost:3000/

# Run tests
zig build test
```

### Ubuntu / Debian

```bash
sudo apt install postgresql-client libpq-dev libsqlite3-dev
zig build
```

---

## Running Tests

```bash
# All tests
zig build test

# Template engine tests only (83 tests, no database required)
zig test src/render/template.zig

# Run SpiderStack (requires PostgreSQL)
cd examples/spiderstack
zig build run
```

---

## Platform Support

Spider is developed and tested exclusively on **Arch Linux**. The following platforms need contributors:

### Windows

Known issues:
- `c.setenv()` / `c.getenv()` in `env.zig` use POSIX C functions — Windows has `_putenv_s` / `getenv` with different signatures
- `std.Io.Threaded` behavior on Windows may differ
- `libpq` and `libsqlite3` linking on Windows needs testing and documentation
- Path separators in `generate_templates.zig` and `views.zig` use `/` — Windows uses `\`

**What we need:**
- Someone to run `zig build` on Windows and document what breaks
- Fixes for the above issues with `#if builtin.os.tag == .windows` guards
- CI setup for Windows (GitHub Actions)

### macOS

Known issues:
- `c.setenv()` should work on macOS (POSIX) but untested
- `libpq` and `libsqlite3` are available via Homebrew but linking is untested
- `epoll` is Linux-only — `Io.Threaded` uses `kqueue` on macOS via Zig stdlib, should work

**What we need:**
- Someone to run `zig build` on macOS and document what breaks
- Homebrew install instructions for dependencies
- CI setup for macOS (GitHub Actions)

### How to contribute platform support

1. Fork the repository
2. Run `zig build` on your platform
3. Document every error you encounter in a GitHub Issue
4. Fix what you can, leave the rest documented
5. Open a PR with a `[platform]` prefix: `[windows] fix env.zig setenv`

This is high-value work — you don't need to understand Spider's internals to help.

---

## Submitting a PR

1. **Fork** the repository and create a branch: `git checkout -b fix/my-fix`
2. **Make your change** — keep it focused, one thing per PR
3. **Run tests**: `zig build test` must pass
4. **Format**: `zig fmt src/` — no unformatted code
5. **Open PR** with a clear description of what changed and why

### PR title conventions

```
fix: correct header iteration after body read
feat: add c.db() method to Ctx
docs: update README with new template syntax
[windows] fix: setenv compatibility
[macos] fix: libpq linking with Homebrew
```

---

## Known TODOs

These are known issues and planned improvements. Good starting points for contributors.

| Area | TODO | Priority |
|------|------|----------|
| `routing/router.zig` | Detect and error on conflicting template names at startup | medium |
| `modules/auth/auth.zig` | `jwtVerify` comptime asserts too rigid — `name` field handling | low |
| `drivers/mysql/` | `query()` parameter binding (`$1`, `?`) not implemented | high |
| `drivers/mysql/` | `caching_sha2_password` auth (MySQL 8 default) not implemented | high |
| `ws/hub.zig` | Race conditions not fully analyzed | high |
| `drivers/odbc/` | ODBC driver for multi-database support | low |
| Templates | Conflict detection: two templates normalizing to same name | medium |
| Templates | Embed mode: `{% include %}` with runtime fallback | low |
| Platform | Windows support | high |
| Platform | macOS CI | high |
| Benchmarks | TechEmpower submission | medium |
---

## Questions?

Open a GitHub Issue or reach Seven on Discord: `llll0ll00ll`
