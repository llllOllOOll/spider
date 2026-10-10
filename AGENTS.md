# AGENTS.md — working on the Spider framework

Spider is a web framework for **Zig 0.17.0** (official releases only, no dev builds; std.Io era): router, middleware,
templates, SSE/WebSocket, auth providers (Keycloak/JWKS, Google, Clerk), Postgres
and SQLite drivers, a `spider` CLI that scaffolds apps. This file is for coding
agents. API reference: `llms.txt`. Human docs: `README.md`.

**The human docs are partly stale.** Many README examples no longer compile
(two-argument routes — the route config `.{}` is required; `c.param()` — it's
`c.params.get()` or `spider.Path`; `pg.init(io, …)` — it's
`init(allocator, io, …)`; a `mysql` driver that doesn't exist). `CONTRIBUTING.md` and
`docs/POSTGRES.md` (libpq era) describe an older tree. When they
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
| Same, scripted local servers | `zig build test-pacman-local` (also with `-Dio_backend=zio`) | — |
| SQLite tests | `zig build test-sqlite` | — (the tests get an env stub as their `spider` module) |
| R2 module tests | `zig build test-r2` | — (signing, addresses, config; no network) |
| xlsx module tests | `zig build test-xlsx` | — (`cd modules/xlsx && zig build test-libreoffice` needs LibreOffice) |
| QR code module tests | `zig build test-qrcode` | — |
| Format | `zig fmt <the files you touched>` | never `zig fmt src` (reformats unrelated files) |

Disposable Postgres for `test-pg`: `docker compose -f docker-compose.test.yml up -d`
(postgres/postgres on 5435, tmpfs). Without the `PG_*` vars the tests target
localhost:5432 as spider/spider — don't point them at a database you care about.
First build fetches dependencies (zio) over the network. zio is pinned to a
commit of its `main` branch (no release tag supports Zig 0.17.0 yet).

Before calling a change done: `zig build test`, and for anything under
`src/core/`, `src/ws/`, `src/routing/` or `src/providers/` also `test-e2e` on
**both** io backends (the default is `threaded`; apps such as Orbitx build with
`-Dio_backend=zio`).

## Rules

- **Everything in this repository is 100% English**, whatever language the
  conversation is in: source, comments, log lines, error messages, test
  names, identifiers, documentation (README, CHANGELOG, llms.txt, this
  file), commit messages, and everything the CLI generates (code, pages,
  messages). Spider is used worldwide. The same holds for the projects
  built with it here: the docs site (`../spiderme-site`) and its example
  app (`examples/posts`). If a request seems to ask for another language
  in the repository, ask before writing it.
- No `Co-authored-by` trailers, and no mention of tools, in commits.
- **Every `pub` name says which side it is on**, right above it: `///` when
  an app uses it (it goes to the API reference: say what it does, what it
  returns, when it fails; a fenced ```zig example on the main entry
  points), or `// internal: why` when it is public only for Spider's own
  files. Every file starts with a `//!` header; a file with nothing for
  apps starts it with `//! Internal:` and needs no per-name notes. Fields
  starting with `_` are internal. `zig build test` fails on a name or a
  file that says neither (`src/doc_check.zig`; the CLI and the tests are
  not checked). Every sentence of a `///` is something the code does:
  check signatures and error names, and take examples from the tests.
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
- `builtin.mode` is `std.lang.Optimize`: `.debug`/`.safe`/`.fast`/`.small` (not `.Debug`, `.ReleaseSafe`, …).
- `std.Uri.getHost`/`getHostAlloc` are gone: `std.Io.net.HostName.fromUri(uri, &buf)`.
- In a binary built with `-fincremental` (what `spider dev` runs), a C library
  *variable* reads as null: `std.c.environ` crashed every HTTP client
  request. Call C functions (`getenv`) instead; they work.
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
  download.zig        Content-Disposition for c.download (file-name rules)
  extractors.zig      spider.Path(T, name) / spider.Form(T) handler params
  watchdog.zig        connection deadlines (idle/header/body/stream write)
  listen_port.zig     the port and host listen() takes (test, dev, PORT, config)
src/routing/          router (trie + static map; RouteMeta), Group (defaults, use),
                      route_config.zig (the route config keys, checked at comptime)
src/render/           template engine: parser → AST → renderer; escaping, RawHtml
src/ws/               Hub (SSE/WS fan-out, channels, replay), Sse, Ws
src/binding/          form + multipart parsing
src/providers/        jwks (JWT via JWKS), keycloak, google, clerk
src/modules/          rbac, logger, static files, health, push (Web Push), auth (HS256),
                      password (argon2id), session (signed cookie login),
                      mail/ (Mailer + provider transports: brevo, resend, postmark, log, memory)
src/internal/         config (spider.Config), env (.env loading), logfmt
src/cli/              `spider` CLI; src/cli/templates/*.template = files it generates
                      dev.zig = `spider dev` (supervises `zig build dev --watch` and
                      the app; build.zig's devStep() + src/dev_notify_tool.zig)
modules/pg|sqlite|r2|qrcode|xlsx   separate packages re-exported as spider.pg etc.
                      (opt-in: -Dpg/-Dsqlite/-Dr2/-Dqrcode/-Dxlsx; xlsx is std only)
modules/pacman        the HTTP client (spider.http_client), always present; uses
                      its own copy of std's http/Client.zig (src/std_http/, with
                      the proxy TLS fix) — builds with an unmodified Zig
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
  Templates are read from disk in a Debug build and embedded in a release
  build (build option `templates`, `ctx_mod.has_embed`): when from disk,
  `root.spider_templates` must stay unreferenced, or the compiler embeds
  the files and every template edit changes the binary again.
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
- **`spider dev`** (`src/cli/dev.zig`, `src/modules/dev_reload.zig`): the CLI
  supervises `zig build dev --watch --cache-dir .zig-cache/dev` (a cache of
  its own: another `zig build` on the same cache made the watching build
  rebuild everything and lose saves made meanwhile) and a COPY of the binary (never the
  cache binary itself: the incremental linker rewrites it in place). The
  browser reload lives in the server, same origin, Debug builds only, on
  when SPIDER_DEV is set: script tag injected into HTML responses, plus
  `/_spider/dev.js` and the `/_spider/dev` WebSocket answered before
  routing. Keep it same-origin (apps send `script-src 'self'`). The tag
  is injected after the middlewares ran, except that `spider.gzip` injects
  it itself before compressing (browsers ask for gzip; curl does not, so
  test with `curl --compressed`). A build
  that changes only the assets (CSS) rewrites the reload file named in
  SPIDER_DEV; the dev socket polls it and sends `reload`. Build helpers in
  build.zig: `devStep` (notify step; never cached) and `watchSources`.
- **Where listen() listens** (`core/listen_port.zig`): a test
  (`spider.testing.start`, one-shot, 127.0.0.1), `spider dev --port`, the
  `.port` given to `listen()`, the `PORT` variable, the config. PORT stays
  after an explicit `.port`: apps (and this repo's `.env`) have a PORT line
  for other uses, and the e2e apps pass their own port.
- **Test helper** (`testing/http.zig`): `spider.testing.start(run)` runs the
  app's serve function on a detached thread and talks to it over a real
  socket. `src/testing.zig` is also compiled alone as the CLI's
  `spider_testing` module: keep `testing/*.zig` free of imports from the
  rest of the framework (`testing/port.zig` is the only link to core).
- **Markdown** (`render/zmd`): everything the author typed is escaped
  (`Formatters.escape`, `safeAddress`). A new formatter that prints
  `node.href`, `node.title` or `node.meta` must escape them.
- **Before routing** (`handleConnection`): `max_body_bytes` (413, checked on
  Content-Length before reading), static files (ETag; `immutable` with `?v=`;
  304), then `origin_check` (core/origin.zig: cross-site unsafe method or WS
  upgrade → 403). `Ctx.clientIp()` uses `trusted_proxies` (core/client_ip.zig).
- **HTTP client** (`modules/pacman`): `src/std_http/Client.zig` is a copy of
  Zig's `std/http/Client.zig` with fixes std lacks (TLS over a proxy tunnel,
  proxy credentials on CONNECT, no https forwarded in the clear). Change it
  only for such fixes and list each one in `src/std_http/README.md`; never
  ask users to patch their Zig. `request.zig` reads the body to the end of
  its framing so the connection returns to the pool. Redirects are not
  followed. A repeatable request (not POST/PATCH) that fails on a POOLED
  connection before any response is sent again on a new one
  (`staleConnection` in `request.zig`): servers close idle connections
  silently. Never retry a new connection, a cancelation (timeouts cancel),
  or a non-repeatable method. Behaviour tests go in `local_test.zig` (no network).
- **Postgres** (`modules/pg/src/pg.zig`): use `query`/`queryOne`/`queryExecute`
  and `begin()`/`transaction()`; the rest is deprecated. `pg.exec("BEGIN")`
  is refused on purpose (each call is a different pooled connection).
  Typed mapping: missing column / NULL into non-optional fails
  (`DbConfig.mapping = .fail`, or `.warn` to log once per field).
- **An app's own users** (`modules/password.zig`, `modules/session.zig`,
  `src/cli/auth_local.zig` + `templates/auth_local/`): what `spider g auth`
  generates by default. `spider.session` signs with `auth.jwtSign` and
  verifies with `auth.jwtPayload` (the generic `jwtVerify` returns string
  claims that point into freed memory: do not use it for new code). The
  generator appends request tests to the project's `src/app_test.zig`
  only when its `run()` starts a database. `spider g auth
  --provider=keycloak` is the older generator (`src/cli/auth.zig`).
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
- `zig fmt` is not a no-op on about ten files (it rewrites `@enumFromInt` /
  `@intFromEnum` into `@fromBackingInt` / `@backingInt`): after formatting
  a file you only meant to touch lightly, look at the diff.
- `test-mysql*.zig` are leftovers; don't treat them as current tests.
- `.env.local` is yours and not in git. `spider.env` loads it, so a `PORT`
  line in it moves any app in this tree that calls `listen()` without a
  port.
- `Config.layout` and `Config.env` are deprecated: nothing reads them. They
  stay so that existing `spider.config.zig` files compile; do not give them
  a meaning, and do not write them in new code or generated files.
