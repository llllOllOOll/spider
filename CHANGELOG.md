# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking changes

- Spider needs the **Zig 0.17.0 release** (`minimum_zig_version` is
  `0.17.0`, for Spider and generated apps). The development build
  `0.17.0-dev.956` no longer builds it. In an app: install Zig 0.17.0, set
  `minimum_zig_version = "0.17.0"`, and rename what the standard library
  renamed (`builtin.mode == .Debug` is `.debug`; `uri.getHost(&buf)` is
  `std.Io.net.HostName.fromUri(uri, &buf)`).
- zio (the `-Dio_backend=zio` runtime) moves from 0.13.0 to its `main`
  branch at 3bbd74d (0.19.0), the first line of zio that supports Zig
  0.17.0. No zio release tag has it yet, so the dependency is pinned to
  that commit.

### Added

- `c.download(bytes, .{ .filename, .content_type })`: answers with a file.
  It sets `Content-Disposition: attachment` (or `.disposition = .@"inline"`),
  the content type and `X-Content-Type-Options: nosniff`. The file name may
  come from user data: paths, control characters, line breaks and quotes
  are removed, it is cut to 120 bytes, and accents and emoji are sent as
  `filename*=UTF-8''…` beside an ASCII name. `spider.content_types` has
  `xlsx`, `csv`, `pdf` and `binary`. An addition only: nothing existing
  changes.
- `spider.xlsx` also **reads** `.xlsx` files: `xlsx.Reader.open(gpa, bytes,
  limits)` lists the sheets and `rows(sheet, .{})` iterates typed rows
  (text, number, boolean, date, time, error; the number format code with
  each cell; formula text on request, never evaluated) straight from the
  compressed part, in bounded memory. Every read is held to limits set per
  call (file size, zip entries, part and total size, compression ratio,
  shared strings memory, rows, columns, cell text, XML depth and sizes),
  with safe defaults and a `large` profile; encrypted files, .xls, .xlsb
  and zip64 are refused with a clear error, and a `<!DOCTYPE` is never
  accepted. It brings its own zip reader over bytes in memory (CRC-32 and
  sizes verified) and its own streaming XML reader.
- `spider.xlsx`: writing Excel `.xlsx` files, in pure Zig (`std` only), as
  an opt-in module (`.xlsx = true` on the dependency, `-Dxlsx=true` here; the
  default build does not compile it). Several sheets; text, numbers,
  booleans, dates and formulas; column widths and row heights; fonts (name,
  size, colour, bold, italic, underline), background colour, borders,
  alignment, wrapped text, shrink-to-fit and number formats; merged cells;
  links to sites and e-mail addresses; hidden rows and columns; frozen
  panes, zoom and a filter per sheet; for printing: paper, orientation,
  margins, scale or fit-to-page, print area, page breaks, repeated header
  rows, header and footer; sheet and workbook protection (a guard against
  accidental edits, not security). The file is
  built in memory and returned as bytes or written to any `std.Io.Writer`.
  User text is always written as text, so it can never become a formula.
  Entries are stored uncompressed for now; no streamed writing yet. See
  `modules/xlsx/README.md`.
- `spider.mail`: sending mail through a provider's HTTP API. A `Mail`
  (`from`, `to`, `cc`, `bcc`, `reply_to`, `subject`, `html`, `text`) goes to a
  `Mailer`, whose backend is Brevo, Resend, Postmark, `log` (development:
  writes the message to the log), `memory` (tests: an `Outbox` to inspect) or
  the app's own `Transport`. `Mailer.fromEnv()` picks it from `MAIL_TRANSPORT`,
  so handlers never name a provider. `send(c, mail)` in a handler,
  `sendWith(arena, io, mail)` in jobs. Messages are validated before they
  leave (sender, recipients, body, address shape, no CR/LF in headers), and
  provider answers map to `MailUnauthorized`, `MailRejected` and
  `MailDeliveryFailed`. Not a mail server; no SMTP and no attachments yet.
- `c.queryDecoded(name)`: the query string value decoded once, with the same
  rules as form fields (`+` → space, `%2B` → "+", `%C3%A3` → "ã"; an invalid
  escape is kept as typed). `c.query(name)` is unchanged and still returns the
  raw value, as documented, so apps that decode it themselves are not
  decoded twice. Use `queryDecoded` for text a user typed: with `query`, a
  search for "João Silva" arrived as "Jo%C3%A3o+Silva" (Orbitx matched the
  "20" of "%20" against CPF digits).

### Fixed

- HTTP client (`spider.http_client`):
  - A persistent `Client` opened a new connection for every request whose
    response was compressed and chunked (most APIs): the end of the body
    was left unread, so the connection could not be reused. It is now read
    to the end and the connection goes back to the pool.
  - https through an HTTP proxy that asks for a password failed: the
    CONNECT request went out without the credentials.
  - When an HTTP proxy refused the tunnel, an https request was sent to the
    proxy unencrypted (`GET https://…`). It now fails with
    `error.ConnectionRefused`.
  - A persistent `Client` with a proxy leaked the proxy settings on
    `deinit()`.
  - `head()` on a response that names a compressed body crashed in release
    builds.
- A request with a body larger than the connection's read buffer (e.g. an
  access device posting an event with a photo) lost its path, headers and
  request id: they pointed into that buffer, which reading the body reused.
  The route stopped matching (no `.public`, so auth middlewares redirected
  to the login) and `c.header()` read body bytes. The head is now copied
  into the request arena before the body is read.

### Changed

- zio is a lazy dependency again: it is only downloaded when something
  builds with `-Dio_backend=zio`. On a clean machine one `zig build` still
  does everything (Zig 0.17.0 fetches it and configures again by itself).
- Spider's `build.zig.zon` no longer lists an old Spider (0.6.8) as a
  dependency of itself. Nothing used it, every app downloaded it, and it
  made `zig build --fork=<local spider>` fail in apps.
- The HTTP client (`spider.http_client`) builds with an unmodified Zig.
  Its proxy support (https through an HTTP proxy, SOCKS5) used to need a
  Zig whose `lib/std/http/Client.zig` had been patched by hand; that file
  now lives in the module, fixed (`modules/pacman/src/std_http/`), and
  goes away when the standard library has the fix. Behaviour is unchanged.
- The HTTP client (pacman, `spider.http_client`) now lives in the monorepo
  (`modules/pacman`) instead of being fetched from its own repository: one
  dependency less to download on the first build. Its sources are the
  standalone repository's at 1c68d77, which adds a fix for an arena leaked
  when a request failed. `zig build test-pacman` runs its tests (they need
  network access).
- Embedded templates are one map built at compile time
  (`src/render/embedded.zig`). `c.view()` / `c.viewFragment()` no longer
  walk every template inside the generic view function or copy every
  template into the request arena: lookup, components and `-- doc` pages
  are handled by non-generic code, and only rendering depends on `data`.
  In Orbitx (297 templates) the Debug binary went from 632 MB to 355 MB, and
  an edited `.html` rebuilds in ~1 s under `zig build --watch -fincremental`
  (was 10–12 s). Rendered pages are unchanged.
- `Template.base_components`: a read-only component map looked up after
  `components` (inline components still win).
- A template name longer than 256 bytes is `error.TemplateNotFound` instead
  of overflowing a buffer.

## [0.7.0] - 2026-09-27

### Breaking changes

- Cross-site request check on by default (`Config.origin_check`): a browser's
  cross-site POST/PUT/PATCH/DELETE or WebSocket upgrade gets 403 before
  routing. Non-browser clients (webhooks, servers) are unaffected; use
  `trusted_origins` / `exempt_paths` for legitimate cross-site posts.
- Request bodies over `Config.max_body_bytes` (10 MiB) get 413.
- `Config.static_dir` is now honored: `null` turns static files off.
- Template interpolation `{ … }` is HTML-escaped by default.
- Removed: `spider.metrics` (never updated by the server), `spider.dashboard`
  (did not compile when used), the `spider_build` module (`setup()` could not
  be imported and ignored `spider.config.zig`).
- Live reload is disabled (`/_spider/reload` is no longer registered; the
  module stays for a future `spider dev`). `Config.env` is not read today.
- `minimum_zig_version` is `0.17.0-dev.956+2dca73595` (Spider and generated apps).

### Added

- App structure: features with `routes.build()`, `server.mountFeatures()`,
  jobs (`spider.every`) and `boot` hooks; `spider.Group` defaults/use/sseWith.
- Route config (third argument, checked at compile time): `.roles`,
  `.org_roles`, `.public`, `.authenticated`, `.policy`, `.quiet_log`,
  `.allow_http`.
- Authorization: `spider.policy`, `spider.resourcePolicy` (+ `spider.Loaded`,
  `c.loaded`), `spider.policySet` (`route`, `can`, `find`).
- Identity from any source: `c.setUser`, `c.userId`, `c.addRole`,
  `c.setRoles`, `c.roles`, `c.addOrgRole`; JWKS/Keycloak/Clerk `roles_claim`,
  `org_claims`, `map_claims`; Clerk active-organization roles.
- Route access tooling: `spider routes [--json|--check|--lock|--diff]`,
  `spider.testing.expectRoutes`, `require_route_access`.
- `spider check` (conventions with file:line and fix; `bool-attr`,
  `route-access`, `kit-class`, …) and `spider.testing.expectConventions`.
- CLI: `spider new` writes `.env`, AGENTS.md; `--ui=daisyui|tailwind`,
  `--pwa`; `spider ui`, `spider icons`, `spider add|remove pwa`,
  `spider g auth` for the features layout; generated `build.zig` picks the
  I/O backend with one line.
- `c.clientIp()` with `Config.trusted_proxies`; `Config.workers` honored.
- Cookies: `c.deleteCookie`, `CookieOptions.domain`, injection-safe values.
- htmx: `c.htmx(.{ … })`, `c.hxEvent`, `spider.varyHtmx`;
  `spider.errorHandler`, `spider.forceHttps`, `KeycloakConfig.fromEnv`.
- Templates: `{ disabled if (cond) }` / `{ "cls" if (cond) }`.
- SSE: `Hub.emitHtmlTo`, `Sse.sendHtml`; multi-line data framed per line.
- Static files: ETag, 304, `immutable` for `?v=` URLs.
- `error.BadRequest` → 400; typed Postgres errors mapped to 409/400/422/503.

### Fixed

- Tokens that fail verification (`jwtVerify`, JWKS) are 401, not 500.
- JWKS rejects tokens issued to other clients of the realm.
- The server keeps accepting after accept errors; connection deadlines.
- SSE hub writes on the server's Io, bounded; a failed client is dropped.
- Live reload script follows the page's scheme (wss on https).
- Form url-decoding, Group handlers known only at runtime, test discovery.

### Docs

- README rewritten and every example compiled against the current code;
  `llms.txt` (API reference) and AGENTS.md for coding agents; exact Zig build
  and how to verify it.

## [0.6.6] - 2026-06-08

### Fixed

- Migration runner no longer splits SQL by `;` — now sends entire SQL block via SimpleQuery,
  fixing `CREATE FUNCTION` with `$$` dollar-quoting that previously broke on multi-line function bodies
- Migration templates now idempotent: `DROP TRIGGER IF EXISTS` before `CREATE TRIGGER` in PostgreSQL,
  `CREATE TRIGGER IF NOT EXISTS` in SQLite

### Added

- Global asset cache for `spider install` — assets downloaded to `~/.cache/spider/`
  (or `~/Library/Caches/spider/` on macOS, `%LOCALAPPDATA%\spider\cache\` on Windows)
  and reused across projects without re-downloading
- Hardcoded asset versions for reproducible installs (Tailwind 4.3.0, DaisyUI 5.5.23,
  Alpine 3.14.8, HTMX 2.0.4, Tabler 3.31.0) — replaces `@latest` URLs
- Alternative PostgreSQL port (5452) in templates to avoid conflicts with local installations
- `.env.example.pg.template` without `SQLITE_PATH` for `--pg` projects

### Changed

- Default PostgreSQL port in `docker-compose.yml.template` and `.env.example.template`:
  `5432` → `5452`
- `spider generate feature` uses correct `.env.example` template based on `--pg` flag

### Removed

- `src/main.zig` — dead code (unused TechEmpower benchmark)

## [Unreleased] — Modular Architecture

### Breaking Changes

- `spider migrate` CLI command removed → use `spider migrate` (new implementation) or `./myapp migrate`
- MySQL and SQLite skeleton drivers removed (will return as proper modules)
- `DriverType` enum removed from `Database` interface

### New Features

#### Modular Modules

- `spider-pg` — PostgreSQL support, opt-in with `-Dpg=true`
- `spider-sqlite` — SQLite support, opt-in with `-Dsqlite=true`, zero config, **default for new projects**
- `spider-r2` — Cloudflare R2 storage, opt-in with `-Dr2=true`

#### CLI

- `spider new myapp` — SQLite by default, server runs immediately without configuration
- `spider new myapp --pg` — PostgreSQL project
- `spider new myapp --api` — no database, no frontend assets
- `spider new myapp --no-db` — no database, with frontend assets
- `spider install` — download frontend assets on demand (spider new is now instant)
- `spider generate feature` — auto-detects database (pg or sqlite) and generates correct SQL syntax
- `spider migrate` — new implementation, supports both SQLite and PostgreSQL

#### Framework

- `sseInterval(ms, callback)` — timer-based SSE broadcasts, Spider manages the thread
- `./myapp migrate` — app binary subcommand for running migrations

### Bug Fixes

- Fixed `intervalLoop` use-after-free (critical) — detached threads accessing freed hub memory
- Fixed `Hub.deinit()` not closing active WebSocket/SSE connections on shutdown
- Fixed `Io.Threaded` handle leak in `app()` and `appWithConfig()`
- Fixed `buildIndex()` error path leaking allocated strings
- Fixed `dupeSentinel` usage for null-terminated strings (Zig 0.17)
- Fixed migration SQL compatibility: SQLite uses `TEXT`/`datetime('now')`/`?1`, PostgreSQL uses `TIMESTAMPTZ`/`NOW()`/`$1`
- Fixed `.env` template: `PG_DATABASE` → `PG_DB`

### Internal

- Memory audit: all confirmed leaks resolved
- `spider-pg`, `spider-sqlite`, `spider-r2` use monorepo structure under `modules/`
- Lazy dependencies via `build.zig.zon` — modules not compiled unless requested
- Test coverage: 13 pg tests, 8 sqlite tests

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
