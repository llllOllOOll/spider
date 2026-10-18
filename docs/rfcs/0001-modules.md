# RFC 0001: Modules — a validated extension contract for Spider

| | |
|---|---|
| **Status** | Accepted — phases 0 to 4 implemented (branch `feat/modules`, Spider 0.11.0-dev.1); see *Implementation* |
| **Author** | Spider maintainer |
| **Created** | 2026-10-17 |
| **Applies to** | Spider 0.10.1 and later |
| **Proving ground** | `spider_notify`, built outside Spider in the Orbitx app |

## Summary

Spider gets a first-class notion of a **module**: a Zig package, written by the
Spider project or by anyone else, that plugs into an app through one
declared contract. The contract is **checked before the module can run**:

- at **compile time**, by Zig: name, version, the range of Spider versions
  it supports, its dependencies and the exact signatures it exposes;
- **before the server listens**, by the module itself: configuration,
  database schema, anything it needs;
- in **CI**, against every Spider release.

A module that does not fit does not compile. A module that is not ready does
not start.

On top of the contract:

- modules ship their own database migrations, which `spider migrate` applies
  without the app copying files;
- the official modules live outside the core, in one `spider-modules`
  repository, gated by an ecosystem CI on every Spider release;
- third parties publish modules the same way, through Zig's package manager.

The core keeps the contracts (HTTP, routing, templates, the hub, jobs, boot,
testing, auth hooks, the database layer). Integrations with outside services
move to modules, one at a time, when there is a reason to.

## Motivation

### Spider already has an implicit module contract

`Server.mountFeature` (`src/core/app.zig`) discovers three things in a
feature namespace by convention: zero-argument functions returning `Group`,
a `jobs` tuple and `pub fn boot(spider.Boot) !void`. It works, but nothing
checks it:

- a function that looks like a route builder but has a different signature
  is **ignored silently**;
- a `boot` with the wrong signature fails with a type error that does not
  name the feature or say what was expected;
- **boot order is declaration order.** The Orbitx app hit this: its
  reservations feature sends notices from `boot()`, and it was declared
  before the notifier it depends on, so the first notices failed. The fix
  was to move a line by hand;
- there is no shutdown hook.

### A real module, built outside Spider, shows what is missing

`spider_notify` (a transactional outbox with retries, deduplication and
inbox, SSE, Web Push, FCM and email channels) was written as a standalone
package that uses only Spider's public API. Wiring it into Orbitx took
manual steps that every other app would have to repeat:

| Need | Today |
|---|---|
| Its tables | copy `sql/notify.sql` into the app's migrations under a new number |
| Start before the features that use it | reorder declarations in `features/mod.zig` |
| Initialization | call `notify.init(...)` from the app's `boot` |
| Its workers | register `spider.every(..., notify.jobFor("sse"))` in the app |
| Database tests | a script of its own with a disposable Postgres |
| Close what it opened | no hook |
| Know its tables are there and current | nothing checks; without the migration, the first send fails at runtime |

### The core grows with every integration

Spider 0.10.1 ships mail providers (Brevo, Postmark, Resend), identity
providers (Clerk, Google, Keycloak, JWKS), Web Push, an S3/R2 client, XLSX
and QR code generators. Each is useful. Each also ties Spider's release
cadence to a vendor's API and adds code that most apps never use. Without a
way out, every new integration has only one place to go: the core.

### Spider cannot grow an ecosystem without it

Today a third party can contribute only through a pull request to the core.
With one maintainer, that does not scale.

## Decisions

| # | Decision |
|---|---|
| D1 | Spider defines a **module contract** (`spider.module(...)` + `server.mountModules(...)`), validated at compile time. |
| D2 | Modules have a **lifecycle**: `check` → `boot` → `shutdown`, run in **dependency order**. `listen()` refuses to start if any `check` fails, and reports every problem at once. |
| D3 | Modules **own their migrations**; `spider migrate` applies them, recorded per module with a checksum. |
| D4 | Spider exposes **its version** (`spider.version`), and every module declares the range it supports. |
| D5 | A small **module API surface** is declared stable (versioned and deprecated, never broken silently); everything else stays internal. |
| D6 | Official modules live in **one `spider-modules` repository**, each a separate package with its own version, gated by an **ecosystem CI** on every Spider release. |
| D7 | Third parties publish modules through **Zig's package manager** (`url` + `hash`); Spider keeps **no registry**, only a list. |
| D8 | **The core keeps contracts; integrations move out.** Extraction happens one module at a time, with a deprecation window, and only when there is a reason. |

## Goals and non-goals

**Goals**
- Plugging in a module takes no manual step beyond declaring the dependency
  and listing the module.
- A module that does not fit (version, dependencies, signatures) **does not
  compile**, with a message naming the module and the problem.
- A module that is not ready (configuration, schema) **does not start**.
- Official modules never fall behind a Spider release unnoticed.
- Third parties can publish without asking the Spider project for anything.

**Non-goals**
- Loading modules at runtime (shared libraries, hot plug). Zig links
  statically; so does this design.
- Sandboxing modules. A module runs with the app's privileges (see
  *Security model*).
- A package registry or marketplace.
- Vouching for the quality of third-party modules.
- Changing how an app's own features (`src/features/*`) work. They may keep
  using `mountFeatures` without a manifest.

## Design

### Terms

- **Core**: the `spider` package.
- **Module**: a package that declares `spider_module` and is mounted with
  `mountModules`.
- **Official module**: a module in the `spider-modules` repository,
  maintained by the Spider project and gated by its ecosystem CI.
- **Third-party module**: any other module.
- **Feature**: an app's own namespace, mounted with `mountFeatures` as today.

### The manifest

```zig
// spider_notify/src/notify.zig
const spider = @import("spider");

pub const spider_module = spider.module(.{
    .name = "notify", // [a-z][a-z0-9_]*, unique in the app
    .version = "0.2.0", // semver, the package's own
    .spider = ">=0.11.0 <0.13.0", // tested Spider versions
    .requires = .{}, // other modules, by name (not Spider's own pieces)
    .migrations = @import("migrations.zig").list,
    .env = .{
        .required = .{},
        .optional = .{ "VAPID_PUBLIC_KEY", "VAPID_PRIVATE_KEY", "FCM_PROJECT_ID" },
    },
});

pub fn check(c: *spider.Check) !void { ... } // reads, never writes
pub fn boot(b: spider.Boot) !void { ... } // opens what it needs
pub fn shutdown(b: spider.Boot) void { ... } // closes it
pub const jobs = .{ ... };
pub const routes = struct { ... };
```

The app mounts it:

```zig
server.mountModules(.{ notify, @import("spider_audit") })
      .mountFeatures(features);
```

### Validation, in three layers

**1. Compile time (`spider.module`, `mountModules`).** Everything that can be
known without running is checked, and a failure stops the build with a
message naming the module, the field and what was expected:

- name, version and range are well formed;
- **`spider.version` is inside the module's range**;
- `check`, `boot`, `shutdown`, `jobs` and `routes` have the exact
  signatures. In a module, a public function shaped like a route builder
  with the wrong signature is an error, never ignored;
- names are unique (a module cannot be mounted twice);
- every name in `requires` is mounted, and there is no cycle;
- the boot order is computed (topological, ties broken by mount order);
- migration names are well formed and unique within the module.

This uses the patterns Zig code already uses for interfaces (`@hasDecl`,
`@TypeOf`, `@compileError`), and the way Spider already validates route
configuration (`src/routing/route_config.zig`).

**2. Before `listen()`.** In dependency order, Spider runs every module's
`check(c)` **before any `boot`**. `spider.Check` collects problems instead
of stopping at the first:

```text
spider: 2 modules are not ready, refusing to start
  notify: migration notify/0003_inbox_index not applied (run `spider migrate`)
  notify: FCM_PROJECT_ID is set but FCM_PRIVATE_KEY is empty
```

Spider itself checks what every module needs:

- the declared required environment variables are present;
- the module's migrations are applied, **with the recorded checksum**, so a
  migration edited after it ran is caught.

The module checks what only it knows, such as a Postgres extension, a role
or the shape of its own tables. This is the same stance as
`require_route_access`: `listen()` refuses a configuration that is known to
be wrong. The same checks run without a server in `spider check --modules`,
for CI and before a deploy, the way Django runs its system checks before
`migrate` and `runserver`.

**3. CI.**

- `spider.testing.expectModules(modules)` runs the compile-time checks and
  every `check` against the test database, as part of `zig build test`.
- `spider modules --lock` records, per module, the surface it brings: its
  routes (method, path, access), jobs, tables, environment variables and
  version. `spider modules --check` fails when an update changes that
  surface without the lock being updated. This is `spider routes --lock`
  extended to modules: a new version cannot add a public route or a table
  without it showing in a diff.

### Lifecycle

```text
compile:  spider.module(...) ─ mountModules(...)        → order fixed, contract valid
listen(): check(all) ── any error? ── refuse to start, list every problem
              │ ok
              ▼
          boot(m1) → boot(m2) → ... → features' boot → accept connections
shutdown: shutdown(mN) → ... → shutdown(m1)              (reverse order)
```

`check` must not have side effects. Following Caddy's split between
constructing, provisioning and validating, opening resources belongs in
`boot`, and releasing them in `shutdown`.

### Migrations

Modules own their migrations and ship them in the package:

```zig
// spider_notify/src/migrations.zig
pub const list = [_]spider.Migration{
    .{ .name = "0001_init", .sql = @embedFile("../sql/0001_init.sql") },
    .{ .name = "0002_inbox", .sql = @embedFile("../sql/0002_inbox.sql") },
};
```

- `zig build` generates, for the app, the list of mounted modules and their
  migrations. `spider migrate` reads it next to `src/core/db/migrations`.
- `schema_migrations` gains `module` (empty for the app) and `checksum`. The
  key becomes `(module, version)`. Existing rows stay valid as the app's.
- The order follows dependencies: required modules first, then each module,
  then the app. Within a module, the name order.
- Each migration runs in its own transaction together with its
  `schema_migrations` row.
- **Escape hatch**: `spider module install <name>` copies a module's
  migrations into the app (the Rails style). From then on they are the
  app's, for teams that must review or adapt every statement.
- Postgres and SQLite: a module declares which dialects it ships. A module
  without SQLite migrations fails `check` on SQLite, with a message.

This is the Laravel `loadMigrationsFrom` and Django per-app model, with
Oban's lesson that the module, not the app, knows its schema versions.

### The module API surface

Modules may only rely on a declared, stable subset of Spider. These are the
names that `API_SURFACE.md` classifies as group A, restricted to:

- `Boot`, `Group`, `every`/`Job`, `Hub`;
- the `pg` transaction and query API;
- `Check`, `Migration`, `module`;
- `testing`;
- `version`.

Inside that subset, a breaking change needs a deprecation of at least one
minor version (before 1.0) and a changelog entry. Outside it, nothing is
promised. The compile-time checks reject nothing outside the subset, but the
ecosystem CI makes breakage visible.

### Compatibility and the ecosystem CI

- `pub const version: std.SemanticVersion` in `spider.zig`, with a test that
  keeps it equal to `build.zig.zon`.
- **Release gate.** Before a Spider release, CI builds each official module
  against the release candidate and runs its unit tests, its database tests
  (disposable Postgres) and its `check`. If an official module fails, the
  release waits.
- **Nightly.** The same against Spider `main`, so breakage is seen the day it
  lands.
- **Tested ranges.** When the gate passes, a bot opens a PR extending each
  module's `.spider` range to the new version. The range states what was
  tested, not what was hoped.
- **Canary apps.** Real apps (Orbitx first) build and run their test suites
  against Spider `main` nightly. They catch what module tests cannot: real
  combinations.
- **Third parties opt in** by adding their repository to a list. Their
  failures notify them; they never block a release.

This is the practice of `vite-ecosystem-ci` (downstream projects tested
against every change) and of Rust's `crater` (the ecosystem rebuilt against
compiler releases).

### Distribution and publishing

- A module is a Zig package (`build.zig.zon` with `name`, `version`,
  `fingerprint`). Apps depend on it by `url` + `hash`, which Zig pins and
  verifies.
- Official modules: one `spider-modules` repository, each module a package
  with its own `build.zig.zon` and version, all `lazy`, so an app fetches
  only what it uses. This is how Spider already ships `pg`, `r2`, `sqlite`,
  `qrcode` and `xlsx` inside its own repository. A module moves to a
  repository of its own only when it needs an independent cadence or
  another maintainer.
- Third-party modules: any repository. Conventions:
  - the package name `spider_<name>`;
  - a manifest;
  - a `README` with install, configuration and the `check` output for a
    missing variable;
  - unit tests;
  - database tests if the module has tables.
- Discovery: a list in the Spider docs, with links and the Spider range each
  module claims. No registry.
- `spider new module <name>` scaffolds a module: manifest, migrations
  folder, `check`, tests, a database test script, and a CI workflow that
  joins the ecosystem list.

### Core versus modules

| Stays in the core | Moves to modules (when there is a reason) |
|---|---|
| HTTP server, routing, middlewares, templates, static files | notifications (`spider_notify`): first module |
| SSE hub, WebSocket, jobs, boot, the module contract | mail providers (Brevo, Postmark, Resend); the `Mailer` interface and the dev adapters (log, memory) stay |
| `spider.testing`, conventions, `spider check` | identity providers (Clerk, Google, Keycloak); the auth hook and JWKS verification stay |
| RBAC, sessions, passwords, the auth marker | S3/R2 client, XLSX, QR code |
| HTTP client (`pacman`) | vendor push senders (FCM); the Web Push primitive stays |
| `pg` and `sqlite`, and `spider migrate` | — |

The rule: **what changes when a vendor changes moves out; what modules need
in order to exist stays.** `pg` and `sqlite` stay because `spider migrate`
and the core depend on them (`src/spider_core_for_pg.zig`). They remain
first-party packages in the Spider repository.

**Deprecation when something moves.** The old name (`spider.r2`, for
example) stays for one minor version as a re-export with a compile-time
deprecation note pointing to the module. It is removed in the next.

**Batteries stay included at creation.** `spider new` asks which modules to
add and wires them: the dependency, `mountModules` and a first
`spider migrate`. The out-of-the-box experience moves from "everything is
always there" to "you pick, and it is wired for you", as Laravel's starter
kits do.

## Advantages

| Area | Advantage |
|---|---|
| Safety | Contract errors become compile errors; missing configuration or schema stops the start, with every problem listed. Today the same mistakes surface at runtime, or are ignored. |
| Architecture | The implicit contract becomes explicit. Boot order is computed, not positional. Vendor code leaves the core. |
| Releases | A vendor API change ships as a module release, not a Spider release. The core changes less often and less riskily. |
| Size of the core | The core stops growing with every integration; the stable surface is small and documented. |
| Blast radius | A bug in a module affects the apps that use that module. |
| Ecosystem | Third parties can publish without touching the core; the Spider project reviews nothing it does not maintain. |
| Database | No copied SQL; per-module history and checksums; drift is detected. |
| Consistency | The design follows mechanisms Spider already has: route configuration validated at compile time, `spider check`, `routes --lock`, `require_route_access`. |

## Disadvantages and mitigations

| Disadvantage | Mitigation |
|---|---|
| A stable surface before 1.0 limits how freely the core can change. | Keep the surface small (D5); deprecate for one minor version; everything else stays internal. |
| More packages, versions and CI for one maintainer. | One `spider-modules` repository; one ecosystem workflow; bot-maintained ranges; extract only when there is a reason (D8). |
| Modules can fall behind Spider. | Release gate on official modules; nightly runs; tested ranges; canary apps. |
| Users must choose and add modules, where today things are just there. | `spider new` asks and wires them; the docs show the common set. |
| Third-party modules will vary in quality. | Validation catches mistakes, not intent; the `--lock` surface makes updates reviewable; the list states each module's tested range. |
| Migrations in packages reduce the app's direct view of its schema. | `spider module install` copies them for teams that need it; `spider migrate` prints each module's pending migrations before applying. |
| Fetching a monorepo brings every official module's source, even unused ones. | Each module is `lazy`; only the fetched archive is shared. To be measured (see *Unresolved questions*). |

## Alternatives considered

| Alternative | Why not |
|---|---|
| **Status quo**: keep everything in the core, modules by convention. | The silent failures and the manual wiring above remain; the core keeps growing; no ecosystem. |
| **Everything into modules now**, including `pg` and `sqlite`. | Too much churn before the contract exists; `migrate` and the core depend on the database layer. |
| **Runtime plugins** (shared libraries). | Against Zig's static model; ABI stability across Zig versions does not exist; no compile-time validation. Caddy and Bevy, the closest prior art, also compile modules in. |
| **Migrations copied into the app only** (Rails). | Every app repeats the step and owns code it did not write; checksums cannot detect drift in copied files. Kept as the opt-in escape hatch. |
| **A version range only, without the release gate.** | A range declared by hand states intent, not fact; modules would break silently on a release. |
| **One repository per official module from the start.** | N workflows and release processes for one maintainer; split later, per module, if needed. |
| **A Spider package registry.** | Zig's package manager already pins and verifies; a registry is a service to run and secure. A list is enough. |

## Prior art

| Project | What this RFC takes from it |
|---|---|
| Caddy (Go) | Modules compiled in (`xcaddy build --with`); a lifecycle that separates construction, `Provision`, `Validate` and `Cleanup`. |
| Bevy (Rust) | Plugins refused when added twice (`is_unique`); one plugin waiting on another (`ready`/`finish`). |
| Django | Per-app migrations recorded by app label; system checks that run before `migrate` and `runserver` and stop on error. |
| Laravel | Packages auto-discovered from their manifest; migrations loaded from the package or published to the app. |
| Rails | Engines; copying migrations into the app (`install:migrations`) as an option. |
| Oban (Elixir) | The library knows its own schema versions; the app only asks it to migrate up to a version. |
| Fastify | A plugin declares the Fastify range it supports and the plugins it depends on; a mismatch fails registration. |
| NestJS | Configuration validated against a schema when the app starts; invalid values stop it. |
| Spring Boot | Starters that configure themselves through declared conditions. |
| Vite (`vite-ecosystem-ci`), Rust (`crater`) | Downstream projects tested against every change or release of the upstream. |

## Security model

A module is compiled into the app and runs with the same privileges, as a
Caddy module does. The validation in this RFC catches **mistakes**:

- an incompatible version;
- a wrong contract;
- a missing dependency;
- a migration not applied, or edited after it ran;
- missing configuration.

It does **not** catch a malicious module. The defenses for that are:

- **pinned hashes** in `build.zig.zon`, which Zig already enforces;
- **the surface lock** (`spider modules --lock`), which makes an update
  that adds routes, jobs or tables visible in review;
- **reviewing the module's diff** before raising its version;
- **least-privilege database roles** where it matters. Orbitx already runs
  part of its work under dedicated roles.

## Roadmap

Versions are targets, not commitments; each phase ships on its own.

| Phase | Target | Deliverables | Done when |
|---|---|---|---|
| **0. Groundwork** | 0.11 | `spider.version` (+ test against `build.zig.zon`); the module API surface listed in `API_SURFACE.md` and marked in the docs | a module can compare versions at compile time |
| **1. Contract** | 0.11 | `spider.module`, `mountModules`, signature and dependency validation, computed boot order, `shutdown`; `mountFeature` reports a public route-shaped function with a wrong signature | `spider_notify` declares a manifest; Orbitx mounts it with `mountModules`; the manual reordering in `features/mod.zig` is gone |
| **2. Readiness** | 0.12 | `spider.Check`; `check()` before `listen()`, with a report of every problem; `spider check --modules`; `spider.testing.expectModules` | starting Orbitx without the notifier's tables refuses to listen and names the migration |
| **3. Migrations** | 0.12 | `spider.Migration`; the generated module list; `spider migrate` per module; `module` and `checksum` in `schema_migrations` (migrated in place); `spider module install` | the copied `1790800000_notify.sql` is removed from Orbitx and `spider migrate` applies the module's migrations |
| **4. First official module** | 0.13 | the `spider-modules` repository; `spider_notify` moved there; the ecosystem CI (release gate + nightly) with a Postgres service; Orbitx as a canary app | Orbitx depends on `spider_notify` only by `url` + `hash`, with no manual step |
| **5. Surface lock** | 0.13 | `spider modules --lock / --check / --diff` | an update that adds a route or a table fails `--check` until the lock is updated |
| **6. Tooling for authors** | 0.14 | `spider new module`; the module list in the docs; the guide "Writing a Spider module"; third-party opt-in to the ecosystem CI | a third party publishes a module following only the guide |
| **7. Extractions** | from 0.14, one at a time | mail providers, identity providers, R2, XLSX, QR code, FCM, each with a deprecation re-export for one minor version; `spider new` offers them | each extraction ships with no change for apps beyond the deprecation note |

Phases 0 to 2 already make it safe to plug a module in: it does not compile
if the contract is wrong, and does not start if something is missing.
Phase 3 removes the last manual step.

## Implementation

Phases 0 to 4 are implemented. What the code does, and where it differs
from the design above:

| Piece | Where | Notes |
|---|---|---|
| `spider.version` | `src/version.zig`, `src/version_check_tool.zig` | A constant plus a `zig build test` step that fails when it differs from `build.zig.zon` (Zig 0.17's build API cannot read the `.zon` text cleanly at configure time). |
| Version ranges | `src/internal/semver.zig` | Comparators `>=`, `>`, `<=`, `<`, `=` or a bare version, all of which must hold, up to four; no `^`/`~`. Work at compile time. |
| `spider.module`, manifest rules | `src/core/module.zig` | Every rule is a function returning the problem as text (`manifestProblem`, `planProblem`, `declProblem`), unit-tested at compile time; `module` and `mountModules` turn a problem into a compile error. An unknown manifest field is an error. |
| `server.mountModules` | `src/core/app.zig` | One call (a second one makes `listen()` fail). Start order: dependencies first, ties keep the given order. `mountFeatures` skips namespaces that declare `spider_module`. |
| Checks before `listen()` | `module.runChecks`, `Server.check` | Run before the address is bound. Spider's own checks first; a module's own `check` is skipped when they failed (it would only repeat the cause). The report lists every problem. |
| `shutdown` | `Server.deinit()` | Spider had no shutdown hook; `deinit()` runs the modules' `shutdown` in reverse order after the jobs stopped. |
| Migrations | `modules/pg/src/migrations.zig`, `Server.migrate` | **Difference:** instead of a new `module` column and a `(module, version)` key, a module's migration is stored in the existing `version` primary key as `module/name` (a `/` never appears in the app's file names), and only a nullable `checksum` column is added. No change of primary key on existing databases; old rows keep working. Each migration runs in its own transaction with its row, under `pg_advisory_xact_lock`. Rows without a checksum count as applied. PostgreSQL only: SQLite modules are left for later. |
| The app's own migrations | `spider.addMigrations` (build.zig), `Server.migrations`, `src/core/migration.zig` | **Beyond the RFC:** the app's files go through the same engine, embedded in the binary, after the modules'. Keys stay the bare file names; existing rows count as applied and get their checksum on the first run. A `BEGIN; ... COMMIT;` wrapping a whole file is left out; a statement PostgreSQL refuses in a transaction (`CREATE INDEX CONCURRENTLY`) runs outside one, alone in its migration. A server then migrates with its own binary (`SPIDER_MIGRATE=1`); `spider.migrating()` lets main() skip what serving needs. Found on the way: the old CLI ran the `-- migrate:down` part of a file without a `-- migrate:up` line; fixed in both. |
| `SPIDER_CHECK`, `SPIDER_MIGRATE` | `Server.listen()` | Like `SPIDER_ROUTES`: the app answers and returns. |
| CLI | `src/cli/modules_cmd.zig`, `check.zig`, `main.zig` | `spider check --modules`; `spider migrate` only runs the binary when build.zig calls `addMigrations(`; otherwise `[--no-modules \| --modules-only]` and the modules' migrations first when `mountModules(` appears under `src/`. |
| Official modules | `spider-modules` repository (local until published) | `notify` is the first: manifest, `src/sql/0001_init.sql`, a `check` that reads its tables, `shutdown`. `scripts/ecosystem.sh` is the gate; `.github/workflows/ecosystem.yml` in both repositories (Spider's is manual until `spider-modules` is published). |
| Not done | — | Phases 5 to 7 (surface lock, `spider new module`, extractions). A stricter `mountFeature` for features (it still skips route-shaped functions with parameters silently, so existing apps keep compiling). |

Tests: the rules (unit, compile time), `Server` with modules (unit, no
network), a real server that starts modules in order and one that refuses
to listen (end to end, both io backends), the migration runner against
PostgreSQL (`test-pg`), and `notify` through Spider on an empty database
(not ready → migrated → ready → its own check failing).

## Unresolved questions

1. **Monorepo dependencies.** Zig fetches a whole archive by URL; this RFC
   assumes an app depends on `spider-modules` and selects modules through
   its `build.zig`, as it does with Spider today. To verify on Zig 0.17,
   including fetch size, before phase 4.
2. **Templates and assets from modules.** Spider compiles templates from the
   app's `views_dir` into `embedded_templates.zig`; a module cannot ship
   views yet. This needs its own design (a per-module templates directory
   merged at build, with name prefixes) before modules with screens.
3. **Routes from modules.** Should a module's routes get a mandatory prefix?
   Should the app be able to remount them? `require_route_access` and the
   surface lock apply either way.
4. **Configuration beyond environment variables.** Is a typed configuration
   struct passed to `mountModules` needed, validated at compile time where
   possible?
5. **Semver before 1.0.** The policy is a deprecation for one minor version.
   Revisit at 1.0.
6. **Down migrations.** Modules ship forward migrations; whether
   `spider migrate` supports stepping a module back (Oban steps back one
   version at a time) is left open.
7. **Features with a manifest.** Should an app's own features be able to
   opt into `spider.module` to get the same ordering and checks?

## References

- Caddy — [Extending Caddy](https://caddyserver.com/docs/extending-caddy), [modules.go](https://fossies.org/linux/caddy/modules.go)
- Bevy — [`Plugin` trait](https://doc.qu1x.dev/bevy_trackball/bevy/app/trait.Plugin.html)
- Django — [System check framework](https://docs.djangoproject.com/en/6.1/topics/checks/), [Migrations](https://docs.djangoproject.com/en/5.2/topics/migrations/)
- Laravel — [Package development (8.x)](https://laravel.com/framework/docs/8.x/packages), [(master)](https://laravel.com/docs/master/packages), [registering migrations in packages](https://www.vincentschmalbach.com/registering-database-migrations-in-laravel-packages/)
- Rails — [`Rails::Engine`](https://gem.sh/gems/railties/v7.0.8.7/classes/Rails::Engine), [engines guide revision](https://demo.gitea.com/TEST_CODEOWNERS/rails/commit/4435959de18652c303a8a8676d27cd913f0578c3)
- Oban — [`Oban.Migrations`](https://oban.hexdocs.pm/2.13.0/Oban.Migrations.html)
- Fastify — [`fastify-plugin`](https://npmjs.com/package/fastify-plugin)
- NestJS — [configurable modules](https://www.coddykit.com/courses/nestjs/building-configurable-dynamic-modules-9251228), [validated configuration](https://www.coddykit.com/courses/nestjs/schema-validated-env-with-joi-and-forroot-9238410)
- Spring Boot — [Creating your own auto-configuration](https://docs.spring.io/spring-boot/reference/features/developing-auto-configuration.html)
- Zig — [`build.zig.zon`](https://git.medv.io/zig/blob/master/doc/build.zig.zon.md.html), [comptime interface checks](https://ziggit.dev/t/comptime-interface-testing/3958), [an alternative to `anytype` duck typing](https://ziggit.dev/t/an-alternative-to-anytype-duck-typing/7814)
- Ecosystem CI — Vite's `vite-ecosystem-ci` and Rust's `crater` (named in the text; links to be added when the document moves to the Spider repository)
