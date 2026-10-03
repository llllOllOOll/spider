# AGENTS.md — working on the Spider framework

Spider is a web framework for **Zig 0.17.0-dev** (std.Io era): router, middleware,
templates, SSE/WebSocket, auth providers (Keycloak/JWKS, Google, Clerk), Postgres
and SQLite drivers, a `spider` CLI that scaffolds apps. This file is for coding
agents. API reference: `llms.txt`. Human docs: `README.md`.

**The human docs are partly stale.** Many README examples no longer compile
(two-argument routes — the route config `.{}` is required; `c.param()` — it's
`c.params.get()` or `spider.Path`; `pg.init(io, …)` — it's
`init(allocator, io, …)`; a `mysql` driver that doesn't exist). `CONTRIBUTING.md`,
`docs/POSTGRES.md` (libpq era) and `tasks.md` describe an older tree. When they
disagree with `src/spider.zig` / `llms.txt`, the code wins.

## Commands

All from the repo root.

| What | Command | Needs |
|---|---|---|
| Build lib + CLI | `zig build` | — (CLI lands in `zig-out/bin/spider`) |
| Unit tests | `zig build test` | — |
| End-to-end (real sockets) | `zig build test-e2e` | free ephemeral ports |
| Same, zio backend | `zig build test-e2e -Dio_backend=zio` | — |
| zio integration test | `zig build test-zio-backend -Dio_backend=zio` | step only exists with that flag |
| Postgres wrapper tests | `PG_HOST=127.0.0.1 PG_PORT=5435 PG_USER=postgres PG_PASSWORD=postgres PG_DB=postgres zig build test-pg` | a **disposable** Postgres (see below) |
| HTTP client tests | `zig build test-pacman` | network access (most tests call httpbingo.org) |
| SQLite tests | `zig build test-sqlite` | **currently fails to compile** (`no module named 'spider'`) — known, see traps |
| Format | `zig fmt <the files you touched>` | never `zig fmt src` (reformats unrelated files) |

Disposable Postgres for `test-pg`: `docker compose -f docker-compose.test.yml up -d`
(postgres/postgres on 5435, tmpfs). Without the `PG_*` vars the tests target
localhost:5432 as spider/spider — don't point them at a database you care about.
First build fetches dependencies (zio) over the network.

Before calling a change done: `zig build test`, and for anything under
`src/core/`, `src/ws/`, `src/routing/` or `src/providers/` also `test-e2e` on
**both** io backends (the default is `threaded`; apps such as Orbitx build with
`-Dio_backend=zio`).

## Rules

- **English only** in source: comments, log lines, error messages, test names.
- Commit messages in English, no `Co-authored-by` trailers.
- Fix with a test that fails first. Unit tests live next to the code; tests that
  need a listening server go in `e2e_test.zig` / `e2e/*.zig`.
- A new test file is **not discovered** unless imported from the `test {}` block
  at the bottom of `src/spider.zig` (Zig only runs tests of the root file and
  whole-file imports). If you forget, `zig build test` fails naming the file
  (`spider.testing.expectAllTestsDiscovered` + the `spider-test-manifest`
  build step; apps get the same via `testManifest()` in `build.zig`).
- `test`, `test-e2e` and `test-sqlite` use Zig's default runner, which fails any
  test that logs at `.err` ("N errors were logged"). Code that errors on purpose
  in tests logs at `.warn` under `builtin.is_test` (see `src/render/renderer.zig`).
  `test-pg` uses `test_runner.zig`, which doesn't have that check.
- Don't bind port 3000 in tests; use `reserveEphemeralPort()` (`e2e_test.zig`).

## Zig 0.17 gotchas seen in this repo

- `std.Io` everywhere: files, sockets, sleep, mutexes take an `io`.
  `std.Io.Mutex`/`RwLock` (need `io`); `std.Thread.Mutex` doesn't exist —
  `std.atomic.Mutex` (`tryLock`/`unlock`) for tiny critical sections.
- `ArrayList` is unmanaged: `.empty`, pass the allocator to every call.
- `**` (array repeat) is rejected: use `@splat`, e.g. `const a: [n]u8 = @splat('x');`.
- `@typeInfo(T).@"struct".field_names` / `.field_types` (not `.fields`).
- Writers need `flush()`; `std.Io.Reader`: `fill`, `peekGreedy`, `toss`, `readSliceShort`.
- A signed int with a width/fill spec prints a sign (`{d:0>2}` of 5 is `+5`); cast to unsigned first.

## Layout

```
src/spider.zig        public API (everything apps import) + test discovery block
src/core/
  app.zig             Server(T): routes, middleware, mountFeatures, listen(),
                      accept loop, handleConnection (request lifecycle),
                      writeRoutes (SPIDER_ROUTES / `spider routes`)
  handler.zig         handler wrapping shared by Server and Group (extractors)
  context.zig         Ctx (per-request API), Response, statusForError()
  extractors.zig      spider.Path(T, name) / spider.Form(T) handler params
  watchdog.zig        connection deadlines (idle/header/body/stream write)
src/routing/          router (trie + static map; RouteMeta), Group (defaults, use),
                      route_config.zig (the route config keys, checked at comptime)
src/render/           template engine: parser → AST → renderer; escaping, RawHtml
src/ws/               Hub (SSE/WS fan-out, channels, replay), Sse, Ws
src/binding/          form + multipart parsing
src/providers/        jwks (JWT via JWKS), keycloak, google, clerk
src/modules/          rbac, logger, static files, health, push (Web Push), auth (HS256),
                      mail/ (Mailer + provider transports: brevo, resend, postmark, log, memory)
src/internal/         config (spider.Config), env (.env loading), logfmt
src/cli/              `spider` CLI; src/cli/templates/*.template = files it generates
modules/pg|sqlite|r2|qrcode   separate packages re-exported as spider.pg etc.
modules/pacman        the HTTP client (spider.http_client), always present; its
                      SOCKS5 path needs a Zig with the http/Client.zig patch
e2e_test.zig, e2e/    end-to-end tests; zio_backend_test.zig
```

## Request lifecycle (src/core/app.zig)

`listen()` → one accept loop per worker (threaded) or one loop on the zio runtime →
`handleConnection` per connection: watchdog deadlines while reading
head/body → static files → `router.match` → middleware chain
(global `.use`, path `.useAt`, then per-route RBAC from `.{ .roles, .org_roles }`)
→ handler → on error: the app's `onError(c, err)` or `statusForError(err)` →
response. Handlers return `!spider.Response`; errors like `error.NotFound`,
`error.Forbidden`, `error.Unauthorized` map to 404/403/401.

Per-request memory: `c.arena` (reset between requests on the same connection).

## Routes and features (how apps are structured)

- Route config (3rd argument, required): `.roles`, `.org_roles`, `.public`,
  `.authenticated`, `.policy` (`spider.policy(name, fn)`, or
  `spider.resourcePolicy(name, T, .{ .load, .check })`, whose resource the
  handler takes as `spider.Loaded(T)`; `spider.policySet(T, .{ .name, .load,
  .rules })` groups a model's rules: `Set.route(.action)`, `Set.can(c, .action, x)`),
  `.quiet_log`, `.allow_http` — validated at compile time
  (routing/route_config.zig). It travels with the route as `RouteMeta`
  (`c.route()`): jwks/keycloak and HS256 auth skip `.public`, the logger
  skips successful `.quiet_log`, `spider.forceHttps` skips `.allow_http`.
- `Group.defaults(config)` before the routes; a route declaring
  `.roles/.org_roles/.public/.authenticated/.policy` replaces the defaults. `Group.use(mw)` wraps
  every route of the group after its RBAC checks (added at mount).
- Apps: each feature exposes `routes.build()` (+ any other zero-arg fn
  returning `spider.Group`), optional `pub const jobs = .{spider.every(..)}`
  and `pub fn boot(spider.Boot) !void`; `main.zig` calls
  `server.mountFeatures(features)` (or `mountFeature(x)` one at a time;
  `mount()` stays for groups that live elsewhere). Route matching doesn't
  depend on registration order.
- App conventions: `src/conventions.zig` (rules) behind
  `spider.testing.expectConventions()` (generated apps run it in `zig build
  test`) and `spider check` (CLI, via the spider_testing module).
- Access checks for apps: `spider.testing.expectRoutes(group, rows)` (a
  feature's method/path/access table as a test), `spider routes
  --check/--lock/--diff` (reads the listing from `SPIDER_ROUTES=json`), and
  `requireRouteAccess()` / `Config.require_route_access` (listen() refuses
  routes that declare no access). "Has auth" = a `use`/`useAt` middleware
  marked by `modules/auth_marker.zig` (providers mark theirs).
- Ready-made app pieces: `spider.errorHandler(.{..})` (onError for JSON /
  htmx toast / page), `spider.forceHttps(.{..})`, `spider.varyHtmx`,
  `KeycloakConfig.fromEnv()`.

## Subsystems — what to know before editing

- **Templates** (`src/render`): `{ expr }` is HTML-escaped. Verbatim only: slots,
  literal component props, `template_helpers` calls, and `spider.RawHtml` values.
  `<script>`/`<style>` bodies are never interpolated. Components are PascalCase
  files; `extends "layout"` for layouts. Recursion is capped
  (`template_max_component_depth`).
  Embedded templates (`spider_templates`) are one comptime map
  (`render/embedded.zig`) read by non-generic code in `Ctx.prepareView`;
  keep anything that depends on template contents out of generic
  (`anytype`) functions — each `data` type instantiates `view()`, so it
  multiplies binary size and invalidates every view on a template edit.
- **io backends**: `threaded` (default; Io.Threaded, blocking sockets) and `zio`
  (fibers, non-blocking sockets, `-Dio_backend=zio`). Anything
  that writes to a socket must use the server's `Io` — a separate Io.Threaded on
  a zio socket gets EAGAIN (this is why hubs are rebound in `listen()`).
- **SSE/WS hub** (`src/ws/hub.zig`): per-slot `io_mutex` + refcount; the hub never
  closes an fd (handleConnection owns it); a failed write `drop()`s the slot.
- **Connection deadlines**: `Config.keepalive_timeout_ms`, `header_timeout_ms`,
  `body_timeout_ms`, `stream_write_timeout_ms`; never applied while a handler runs.
- **Before routing** (`handleConnection`): `max_body_bytes` (413, checked on
  Content-Length before reading), static files (ETag; `immutable` with `?v=`;
  304), then `origin_check` (core/origin.zig: cross-site unsafe method or WS
  upgrade → 403). `Ctx.clientIp()` uses `trusted_proxies` (core/client_ip.zig).
- **Postgres** (`modules/pg/src/pg.zig`): use `query`/`queryOne`/`queryExecute`
  and `begin()`/`transaction()`; the rest is deprecated. `pg.exec("BEGIN")`
  is refused on purpose (each call is a different pooled connection).
  Typed mapping: missing column / NULL into non-optional fails
  (`DbConfig.mapping = .fail`, or `.warn` to log once per field).
- **Auth**: `keycloak.Keycloak` wraps `jwks.JwksAuth`; tokens must be issued to
  the app's client (`audience`, defaults to `client_id`). RBAC reads the
  `_auth_*` params; providers set them (`JwksConfig.roles_claim` /
  `org_claims` / `map_claims` decide which claims) and apps can too via the
  Ctx identity API (`setUser`, `addRole`, `addOrgRole`). Apps (Orbitx) read
  `_auth_org_N_{id,name,role}` / `_auth_orgs_count` directly: keep that layout.

## Known traps in this repo

- `src/cli/build.zig` is a stale template copy, not the CLI's build (the CLI is
  built by the root `build.zig`); generated-project templates are
  `src/cli/templates/*.template`.
- `tasks.md`, `memory.md`, `test.sh`, `test-mysql*.zig`, `server.log`,
  `test.db` are leftovers; don't treat them as current plans or tests.
- `spider.livereload` is disabled (not registered by the server); kept for a
  future `spider dev`. `Config.env` is not read by anything today.
- `zig build test-sqlite` doesn't compile (the sqlite module imports `spider`,
  which that test step doesn't provide).
