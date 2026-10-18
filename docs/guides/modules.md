# Modules

A module is a package that plugs into a Spider app through one contract:
a manifest Spider checks at compile time, optional `check`, `boot`,
`shutdown`, `jobs` and `routes`, and its own database migrations. A module
that does not fit does not compile; a module that is not ready keeps the
server from listening. The design and the decisions behind it are in
[RFC 0001](../rfcs/0001-modules.md).

## Using a module

1. Add the package and give it your `spider` module (a module never brings
   a Spider of its own):

   ```zig
   // build.zig
   const modules_dep = b.dependency("spider_modules", .{});
   const notify_mod = b.createModule(.{
       .root_source_file = modules_dep.path("notify/src/notify.zig"),
       .target = target,
       .imports = &.{.{ .name = "spider", .module = spider_mod }},
   });
   exe.root_module.addImport("spider_notify", notify_mod);
   ```

2. Mount every module in one call, before the features:

   ```zig
   // main.zig
   const notify = @import("spider_notify");

   var server = spider.app(.{});
   defer server.deinit();
   try server.mountModules(.{notify}).mountFeatures(features).listen(.{});
   ```

3. Apply its migrations and check it:

   ```sh
   spider migrate            # the modules' migrations, then the app's
   spider check --modules    # what listen() checks before it starts
   ```

When something is missing, `listen()` refuses to start and says what:

```text
spider: 1 module(s) not ready, refusing to start
  notify: migration notify/0001_init is not applied (run `spider migrate`)
```

In tests, `server.check(arena, io)` returns the same report:

```zig
const report = server.check(arena, io);
try std.testing.expect(report.ok());
```

## Writing a module

The root file of the package declares the manifest:

```zig
const std = @import("std");
const spider = @import("spider");

pub const spider_module = spider.module(.{
    .name = "audit",
    .version = "0.1.0",
    .spider = ">=0.11.0 <0.12.0",
    .requires = .{}, // other modules it needs, by name
    .migrations = .{
        .{ .name = "0001_init", .sql = @embedFile("sql/0001_init.sql") },
    },
    .env = .{ .required = .{"AUDIT_SINK_URL"}, .optional = .{"AUDIT_BATCH"} },
});

pub fn check(c: *spider.Check) !void {
    const url = c.env("AUDIT_SINK_URL") orelse return; // Spider already reported it
    if (!std.mem.startsWith(u8, url, "https://"))
        c.fail("AUDIT_SINK_URL must be https (it is {s})", .{url});
}

pub fn boot(b: spider.Boot) !void {
    _ = b; // open what the module needs
}

pub fn shutdown(b: spider.Boot) void {
    _ = b; // close it
}

pub const jobs = .{spider.every(60_000, flush)};

fn flush(hub: *spider.Hub) void {
    _ = hub;
}

pub const routes = struct {
    pub fn build() spider.Group {
        var g = spider.Group.init("/audit");
        // ...
        return g;
    }
};
```

### What Spider checks at compile time

| Rule | Message names |
|---|---|
| `.name` matches `[a-z][a-z0-9_]*`, at most 64 bytes | the field and the value |
| `.version` is semver | |
| `.spider` is a range and contains `spider.version` | the range and this Spider's version |
| `.requires`: module names, not itself, no repeats; every one mounted in the same `mountModules` call; no cycle | the missing module, or the modules in the cycle |
| migrations named `NNNN_description`, in increasing order, with SQL | the migration |
| env names `[A-Z][A-Z0-9_]*`, unique | the name |
| `check`, `boot`, `shutdown` with these exact signatures; `jobs` a tuple of `spider.every`; a `pub fn` in `routes` returning `spider.Group` takes no parameters | the declaration and the expected signature |
| a module mounted twice | the module |

### Lifecycle

```text
compile   spider.module + mountModules: manifests, signatures, order
listen()  checks of every module ─ any problem? refuse to start, list them all
          boot(module 1) → boot(module 2) → … → the features' boot → serve
deinit()  jobs stop → shutdown(module N) → … → shutdown(module 1)
```

`check` must not change anything: it runs before any module boots, and
`spider check --modules` runs it on a server that never starts.

### Migrations

- One file per migration in the package (`src/sql/0001_init.sql`), listed
  in the manifest in the order they run. PostgreSQL, forward only.
- No `BEGIN`/`COMMIT`: Spider runs each one in its own transaction, with
  its row in `schema_migrations` (`version` = `module/name`, `checksum` =
  SHA-256 of the SQL). A migration with transaction control is refused
  before anything runs.
- **Never edit a released migration.** An applied migration whose SQL
  changed stops `spider migrate` and the start (`error.MigrationChanged`):
  add `0002_...` instead.
- A first migration that may meet tables an app created by hand should use
  `CREATE ... IF NOT EXISTS`, so applying it only records it.

### Testing a module

- Unit tests next to the code.
- With tables, a test that goes through Spider on a disposable database:

  ```zig
  var server = spider.app(.{});
  defer server.deinit();
  _ = server.mountModules(.{my_module});
  try std.testing.expect(!server.check(arena, io).ok()); // migrations pending
  _ = try server.migrate(arena);
  try std.testing.expect(server.check(arena, io).ok());
  ```

### Packaging

- `build.zig.zon` of its own, with a real `fingerprint`, and **no
  dependency on Spider**: the app passes `spider` in as an import.
- The official modules live in the `spider-modules` repository, whose
  `scripts/ecosystem.sh` builds and tests them against a Spider checkout:
  it is Spider's release gate, and a module's `.spider` range says which
  versions it passed on.
- A repository of modules whose root `build.zig` depends on Spider for its
  own tests returns early when it is not the root build
  (`if (!b.isRoot()) return;`): an app that depends on it only takes the
  modules' files, and a second Spider in the app's build would share its
  `spider_pg` with the app's ("file exists in modules 'spider' and
  'spider0'").

## The app's own migrations

The app's migrations can go through the same engine as the modules', in
the binary:

```zig
// build.zig: every *.sql file of the folder, by name
exe.root_module.addImport("migrations", @import("spider").addMigrations(b, spider_dep, "src/core/db/migrations"));

// main.zig
const modules = .{notify};
const migrations = @import("migrations").all;

try spider.pg.init(allocator, io, .{});
defer spider.pg.deinit();
// `spider migrate`: migrate and return, before anything serving needs
// (an identity provider, a cache).
if (spider.migrating()) {
    var migrator = spider.app(.{});
    defer migrator.deinit();
    return migrator.mountModules(modules).migrations(migrations).listen(.{});
}
var server = spider.app(.{});
defer server.deinit();
try server.mountModules(modules).migrations(migrations).mountFeatures(features).listen(.{});
```

- **Same rules, same table.** The modules' migrations run first, then the
  app's, each in its own transaction with its `schema_migrations` row,
  under the lock, with a checksum. An app's migration is recorded under
  its bare file name, as `spider migrate` always did, so the rows already
  there count as applied; the first run records their checksums, and an
  edit is caught from then on.
- **Old files keep working.** A file runs from its `-- migrate:up` line
  (or its start) up to `-- migrate:down` (or its end). A `BEGIN; ...
  COMMIT;` around all of it is left out (the transaction is Spider's); any
  other transaction control is refused. A statement that PostgreSQL
  refuses in a transaction (`CREATE INDEX CONCURRENTLY`, `VACUUM`, ...)
  must be alone in its migration, and then runs outside one.
- **`listen()` refuses to start** while one of them is pending or changed
  (the report's owner is `app`).
- **Migrating a server needs only the binary**: `SPIDER_MIGRATE=1 ./app`
  with the same environment as the app. `spider migrate` sees
  `addMigrations(` in build.zig and runs `zig build run` with
  `SPIDER_MIGRATE` set.
- Applying stays a step of its own: nothing migrates when the app starts.

## Errors

| Error | From | Meaning |
|---|---|---|
| `error.ModulesNotReady` | `listen()`, `SPIDER_CHECK` | a module's checks failed; the report is in the log |
| `error.NoDatabase` | `migrate` | the app is built without `-Dpg=true` |
| `error.DatabaseNotInitialized` | `migrate`, checks | `spider.pg.init` was not called before |
| `error.MigrationChanged` | `migrate` | an applied migration was edited |
| `error.MigrationHasTransactionControl` | `migrate` | BEGIN/COMMIT/ROLLBACK inside a migration |
| `error.MigrationNotAlone` | `migrate` | a statement that cannot run in a transaction shares its migration with others |
