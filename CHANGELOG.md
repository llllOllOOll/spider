# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`c.io()`**: the `std.Io` the server runs on, for code inside a request
  that needs one (the HTTP client, files, sleep). It replaces reading the
  field `c._io`, which keeps working.
- **`static_max_file_bytes`** in `spider.config.zig`: the largest static
  file served. The limit was already there, fixed at 10 MiB and unnamed: a
  bigger file answered 404 with a log line that only said
  `StreamTooLong`. The default is the same; the log now names the file,
  the limit and the setting.
- **Google sign-in, complete: `spider.google.login` and
  `spider.google.callback`.** `login(c, config)` sends the visitor to
  Google with a random `state` that it also keeps in a cookie;
  `callback(c, config)` refuses a callback whose state is not this
  browser's (someone else finishing a login in the visitor's browser),
  then trades the code and returns the profile. `authUrlWith(arena,
  config, .{ .state })` is there for an app that keeps the state its own
  way.
- **`server.wsWith(path, handler, config)`**: a WebSocket route that says
  who may open it, like `sseWith`. `ws()` took no config, so its routes
  declared no access: any app with a WebSocket route could not start with
  `require_route_access` on, and a socket could not be limited to signed-in
  users at the route. A request that fails the checks is answered 401 or
  403 before the protocol is switched.
- **`current_user` in every view.** When the request has a user (a session,
  a token, `c.setUser`), templates can read `current_user.id`,
  `current_user.email` and `current_user.name` without the handler passing
  them, in the layout and in components too: `if (current_user) { ... }
  else { ... }`. A handler that passes its own `current_user` keeps it.

### Changed

- **SSE streams are no longer readable from any site.** Every stream
  answered `Access-Control-Allow-Origin: *`, fixed in the code: a page on
  any other site could read a stream that did not depend on cookies. The
  header is now sent only to the origins listed in `sse_allowed_origins`
  (`spider.config.zig`), naming the origin. **An app whose streams are
  read from another origin must list it** (or `&.{"*"}` for the old
  behaviour). An app that reads its own streams changes nothing.
- **The process's own environment wins over every `.env` file.**
  `.env.<SPIDER_ENV>` and `.env.local` used to replace variables the
  process already had (a container's `PORT`, a secret set by the
  platform); only `.env` respected them. Now no file does: the files fill
  in what is missing, `.env.local` over `.env.<SPIDER_ENV>` over `.env`,
  as before among themselves. This is what Next.js, Vite, Rails and
  Symfony do. **A deploy that ships a `.env.production` or `.env.local`
  whose value differs from the container's now gets the container's.**
- **Forms: a number field with text that is not a number is an error.**
  `c.parseForm` and `spider.Form` turned "12,50" or "abc" in a number
  field into 0 and went on. It is `error.InvalidNumber` now, a 400. A
  number field left blank is still accepted (it counts as not sent).
  **A form that relied on bad input becoming 0 now answers 400**: validate
  on the page, or take the field as text and convert it yourself.
- **SQLite: a row that does not fit the struct is an error.** A struct
  field with no column of its name used to get 0, `""` or `false` without
  a word, and a NULL column read into a field that is not optional became
  `""` or 0. They are now `error.ColumnMissing` and `error.UnexpectedNull`,
  logged with the struct and the field, as in `spider.pg`. To say that a
  value may be absent, make the field optional (`?[]const u8`) or give it
  a default (`role: []const u8 = "user"`). **An app that relied on the
  silent zero has to change its struct or its SELECT.**
- **An object is true in a template condition.** `if (post) { ... }` used
  to be false whatever `post` held; it is now true when the name holds an
  object.

### Fixed

- **A WebSocket client could stop the whole server with one frame.** A
  frame with a reserved opcode made the server panic. It now closes that
  connection with code 1002 (protocol error) and keeps serving.
- **Web Push: a subscription with keys of the wrong size crashed the
  sender.** `p256dh` and `auth` come from the browser; a longer value
  made `send` panic (and write outside a buffer in a ReleaseFast build), a
  shorter one left part of the key undefined. Both are now
  `error.InvalidKeyLength`, as is a VAPID private key of the wrong size.
- **SQLite: `defer tx.rollback()` after `tx.commit()` broke the pool.**
  The rollback gave the connection back a second time: a panic, or two
  transactions on one connection. A transaction now remembers that it
  ended; a second `commit()` or `rollback()` does nothing, as in
  `spider.pg`.
- **`Ws.joinUser` never delivered.** The channel name was kept in memory
  that ended with the call, so a message sent to `user:<id>` found
  nobody. (`Sse.joinUser` had been fixed for the same thing.)
- **Clerk: the provider used memory it had freed.** `Clerk.init` freed the
  address of the key set while the token verifier kept it, so the first
  token signed with a key it had not seen yet crashed the server; and the
  callback answered with headers that no longer existed by the time they
  were sent (seen in optimized builds). `deinit` now also frees the two
  addresses `init` builds.
- **PostgreSQL: a date before 1970 could not be read as text.** A `date`,
  `timestamp` or `timestamptz` earlier than 1970-01-01 read into a
  `[]const u8` field failed with `error.TypeMismatch` (a birth date, for
  one). They now come back like the others, from year 1 on.
- **PostgreSQL: `pg.array(T, values)` never worked.** Every query that
  used it failed with `error.CannotBindStruct`. It now sends the list, as
  a plain slice parameter already did.
- **WebSocket: `Ws.send` could mix its bytes with a broadcast.** A
  handler's own `send` wrote to the socket without the lock that
  `broadcast` from other connections takes, so two frames written at the
  same moment corrupted the stream. `send` now takes the same lock.
- **SSE: an error returned by a stream's handler left no trace.** It was
  dropped silently. The server now logs it, with the request id and the
  path; a client that simply went away is still not logged.
- **A stream whose handler returned was left open.** After an SSE or
  WebSocket handler returned, the server kept the connection and waited
  on it for another HTTP request, so the client only learned that the
  stream was over when the idle timeout closed it. The connection is now
  closed as soon as the handler returns.
- **SQLite: `query(i64, ...)` answered 0 when the statement failed.** A
  statement that failed while running looked the same as one with no row.
  The error is returned now, for `spider.sqlite.query` and inside a
  transaction.
- **`spider.auth` middleware: a public path with a query string was not
  public.** `public_paths` was compared with the path and its query
  string, so `/login?next=/home` was sent back to the login page. Only the
  path counts now.
- **Google sign-in: a refused code looked like a parse error.**
  `fetchProfile` did not look at the status of Google's answers. A code
  Google refuses is `error.OAuthCodeRejected` (401), a profile it does not
  return is `error.OAuthProfileFailed` (502), and the reason goes to the
  log.
- **Google sign-in: the redirect address was not URL-encoded.** A
  `redirect_uri` with a query string of its own leaked its parameters into
  Google's URL. `client_id` and `redirect_uri` are encoded now.
- **HTTP client: `params` and `query` did not work together, and a
  param value was not encoded.** With both options the `:name`
  placeholders were left in the address; and a value with `/`, `?` or a
  space changed the address asked for. Values are URL-encoded now and the
  two options combine.
- **`spider.forceHttps` behind two proxies redirected forever.** The
  protocol header had to be exactly `https`; a chain of proxies sends a
  list (`https, http`). The first value, the client's, decides now, in
  any letter case.
- **HTTP client: a `Client` ignored the headers of each request.**
  `client.get(path, .{ .headers = ... })` sent only the headers given to
  `Client.init`. Both are sent now; a request header with the name of a
  client header replaces it for that request.
- **Markdown: an underscore inside a word started italics.**
  `max_body_bytes` came out as "max", italic "body", "bytes", and two
  names on one line lost an underscore each. `_` now opens italics only at
  the start of a word and closes them at the end of one, as in CommonMark:
  names stay as written, `_this_` is still italic, and `*` is unchanged.
- **Markdown: `zmd.parseFull` ignored custom formatters.**
  `parseFull(a, text, .{ .h1 = heading })` threw the whole value away
  unless `root` was customised too. The formatters given are used now, in
  `parseFull` and in `parse`.
- **Forms: the defaults of the struct were ignored.** With `per_page: u32
  = 20`, a form that did not send `per_page` gave 0. A field the form does
  not send now takes its default. (A checkbox is the exception: not sent
  means unchecked, so it is false whatever the default.)
- The two files the build writes for an app without its own
  (`spider_config.zig`, `template_helpers.zig`) end with a newline, so
  `zig build` documentation of an app no longer reports them as errors.

## [0.9.2] - 2026-10-09

A login that needs nothing outside the app, tests that call the app, and a
fix for `spider dev`. Existing projects are not changed by updating: the
generators only affect what they generate from now on.

### Changed

- **`spider g auth` generates a login with the app's own users.** The
  Keycloak login it used to generate is now `spider g auth
  --provider=keycloak`. A project that already has its auth feature is not
  touched.
- **`spider new` splits `src/main.zig` in two**: `main()` sets up the
  database and calls `pub fn serve(allocator, io)`, which builds the server
  and listens. The tests call `serve` too.

### Added

- **`spider g auth`**: `src/features/auth/` with a users table (migration),
  sign in, sign up, sign out and an account page. `--api` generates JSON
  routes that answer a bearer token instead of pages. It adds
  `spider.session.middleware()` to `src/main.zig`, sends a visitor without
  a session to the sign-in page, and appends tests of the whole flow to
  `src/app_test.zig`. Nothing outside the app is involved, so the tests
  run anywhere. Works with SQLite and PostgreSQL; a project without a
  database is told why it cannot have a login.
- **`spider.password`**: `hash(c, password)` and `verify(c, stored,
  password)` (argon2id with OWASP's parameters, a PHC string for one text
  column), and `decoy`, a hash to verify against when the account does not
  exist, so a missing account takes as long to refuse as a wrong password.
- **`spider.session`**: `start(c, user)` and `end(c)` give the response
  options that write and clear a signed cookie (HS256, with the user's id,
  email, name and roles); `token(c, user)` gives the token for an API;
  `middleware()` reads the cookie or an `Authorization: Bearer` header,
  fills in the request's user (what `.authenticated`, `.roles` and
  `c.userId()` check) and answers 401 on a route that is not `.public`. A
  request that matches no route still gets its 404. The secret is
  `JWT_SECRET`; without one a debug build makes one up for the run and a
  release build refuses to sign. There is no table of sessions: a session
  cannot be revoked before it expires (14 days by default).
- **`spider new` writes `src/app_test.zig`**: a first test that sends a
  request to the running app with `spider.testing.start`, on a scratch
  database in a SQLite project. A new project's `zig build test` starts
  its own server from the first day.
- `spider.testing`: `app.with(headers)` is the same app sending those
  header lines with every request, for a test that acts as a signed-in
  visitor.
- `c.hasRoute()`: false for a request no route matched, so a middleware
  that guards routes can let it through to its 404.
- `spider.auth.jwtPayload(alloc, token, secret)`: the verified payload of
  an HS256 token.
- `spider check` counts `spider.session.middleware()` as authentication.

### Fixed

- **`spider dev` lost changes after another `zig build` ran in the
  project.** Running `zig build test` in a second terminal made the
  watching build recompile everything; a file saved during that rebuild
  (a generator writing several) was compiled half-written and not again,
  so the app kept running without the change. The build of `spider dev`
  now has a cache of its own, `.zig-cache/dev`. The first `spider dev`
  after updating builds from scratch once.

### Known limits

- The generated login has no password reset, email confirmation, limit on
  sign-in attempts or two-factor.
- A PostgreSQL project gets the login but not its request tests: the test
  server of a generated PostgreSQL project starts no database.
- `spider.auth.jwtVerify` with claims other than `spider.auth.Claims`
  returns text that may point to freed memory. `spider.session` does not
  use it; prefer `jwtPayload` in new code.

## [0.9.1] - 2026-10-09

Fixes found while writing the new documentation site and its example app,
and one found in production (the HTTP client on connections the server
closed). Nothing here asks an existing app to change its code; "What an
app may notice" lists the differences in behaviour.

### What an app may notice

- Markdown output: quotes in text are written as `&quot;` / `&#39;`, and
  what used to pass through unescaped (see Security) no longer does.
- `sqlite.queryExecute` and the PostgreSQL script calls no longer split a
  script on every `;`.
- An app that calls `listen()` WITHOUT a port takes `PORT` from the
  environment or `.env` when it is set. An app that passes `.port` is not
  affected.
- A persistent HTTP `Client` closes connections idle for more than 30 s.
- Only for projects created from now on: migrations applied at startup,
  `listen(.{})`, the new Dockerfile, no compose file without `--pg`.

### Security

- **Markdown (`spider.zmd`) wrote what the author typed unescaped** in four
  places: a link's address and text, an image's address and title, the
  language of a code block, and the body of a `{% raw %}` block. A document
  could inject markup (`[x](https://a" onmouseover="...)`) or a script. All
  are escaped now, quotes included, and a link or image whose address has a
  scheme other than `http`, `https` or `mailto` (`javascript:`, `data:`)
  keeps only its text. An app that renders Markdown from its users should
  update.

### Added

- `spider.testing.start(run)`: an app's tests send real requests to its
  server. `run` is what `main()` does to serve; it runs on a thread, once
  per test binary, and its `listen()` takes a free port on 127.0.0.1. The
  `App` has `get`, `postForm`, `postJson`, `request`; a `Response` has
  `status`, `header`, `cookie`, `body` and `expectStatus`, `expectContains`,
  `expectNotContains`, `expectHeader`, `expectRedirect`.
- `c.redirectWith(url, opts)`: a redirect with headers or cookies, 303 by
  default (`c.redirect` takes none and answers 302):
  `c.redirectWith("/posts", try c.withCookie("author", name, .{ .encode = true }))`.
- `CookieOptions.encode` percent-encodes a cookie's value, so text a person
  typed (an accent, a `;`) is valid; `c.cookieDecoded(name)` reads it back.
- `PORT` (the environment or `.env`) sets the port of an app that does not
  pass one to `listen()`. Order: `spider dev --port`, `listen(.{ .port })`,
  `PORT`, `spider.config.zig`. New projects call `listen(.{})`.
- Markdown: a line starting with `> ` is a blockquote.
- `zig build test-sqlite` compiles and runs again.

### Fixed

- **Router**: two routes that name the param at the same position
  differently (`GET /posts/:author`, `POST /posts/:id`) each get their own
  name. The second used to answer 400, "missing path param". `spider
  routes` lists each route as it was declared.
- **SQLite**: `queryExecute` (and `exec`) ran a script by splitting it on
  every `;`, which cut a `CREATE TRIGGER` and any `;` inside a string. The
  generated `src/core/db/migrations.zig` could not apply the migration
  `spider g feature` writes. The script now runs as one piece.
- **PostgreSQL**: `queryExecute`, `execRaw` and the `Database` bridge split
  a script on every `;`, and the transaction guard did the same, so a
  plpgsql function body (`$$ BEGIN ...; END; $$`) failed with
  `UseBeginForTransactions`. Statements now end only outside strings,
  quoted names, dollar-quoted bodies and comments.
- **Generated apps apply pending migrations when they start**
  (`core.db.migrations.migrate()` in `main.zig`): a container or a fresh
  clone has its tables on the first request. `spider migrate` still works
  and shares the same bookkeeping table.
- **HTTP client: a persistent `Client` failed on connections the server
  had closed.** Servers close idle keep-alive connections without a word
  (Cloudflare R2 within minutes); the next request went out on the dead
  socket and failed at once with `error.HttpConnectionClosing`, once per
  dead connection in the pool. Seen in production as R2 reads failing after
  a quiet period, and in bursts when a page asked for several objects.
  Now: a GET, HEAD, PUT, DELETE, OPTIONS or TRACE that fails on a pooled
  connection before any response arrives is sent again on a new connection
  (the other idle connections to that host are closed first); a connection
  idle for more than 30 s is not reused (`Client.init(.{ .idle_timeout_ms
  })`, 0 for no limit); `.keep_alive = false` opens a connection per
  request. A POST or PATCH is not repeated: the server may have received
  it. `spider.r2` only uses the repeatable methods.
- **Generated Dockerfile**: it used an image with a Zig older than 0.17.0
  and did not build. It now downloads the official Zig release, checks its
  checksum, and installs the `spider` command for the assets the build
  downloads. New: a `.dockerignore` (`.env`, databases, local builds).
- **A fresh clone of a generated project**: `zig build test` builds the
  template index first (it is no longer kept in git); `spider migrate`
  reads `.env.example` when there is no `.env`; `.gitignore` lists
  `db.sqlite`.
- `spider new`: `docker-compose.yml` only for `--pg` projects, on a port
  picked from the app's name (it was 5452 in every project);
  `.env.example` only has the settings of the project's database.
- `spider new` and `spider update` save a released tag of Spider, not the
  tip of `main`.
- `spider self-update` falls back to the install script in the repository
  when spiderme.org does not answer.
- `spider g feature` adds its line next to the others in
  `src/features/mod.zig` (it went after the tests).

## [0.9.0] - 2026-10-08

### Breaking changes

- **Templates are read from disk in a Debug build** and embedded only in a
  release build (`-Doptimize=ReleaseSafe`/`Fast`/`Small`). Until now an app
  that declared `spider_templates` embedded them in every build. A Debug
  binary now needs its template directory (`views_dir`) beside it; it says
  so when it starts. Deploys that build in a release mode (the generated
  Dockerfile does) are unchanged. To embed in every build as before, pass
  `.templates = .embedded` to the spider dependency in `build.zig`
  (`.disk` forces the other way). The rule follows the `optimize` the app
  passes to the dependency: an app that does not pass it gets Debug, hence
  disk, even in its own release build — pass `.optimize = optimize`.

### Removed

- `spider.livereload` (`src/modules/livereload.zig`): the old live reload,
  which was never wired in. `spider dev` replaces it.

### Added

- `spider dev`: builds the app, runs it, and replaces it after every build
  that succeeds. It runs `zig build dev --watch` (incremental compilation on
  x86_64 Linux: an edit is back on the page in well under a second in a
  generated app) and starts a copy of the new binary each time. While a
  build runs or after it fails, the app that is up keeps serving and the
  compiler's errors go to the terminal. Ctrl+C stops the build and the app.
  One `spider dev` per project. Not on Windows yet. `--port N` makes the
  app listen on N instead of the port in its code. In an app without the
  `dev` build step it says which lines to add to `build.zig`.
- Under `spider dev` the browser reloads by itself after each build. The
  app (Debug builds only, when `spider dev` started it) adds a small script
  to its HTML pages and serves it and a WebSocket at `/_spider/dev.js` and
  `/_spider/dev`, before routing and before any middleware, so an app's
  auth does not get in the way. The script reloads the page when the
  process it was connected to has been replaced by a new one; a failed
  build reloads nothing. Everything is same-origin, so it works under a
  `script-src 'self'` / `connect-src 'self'` Content-Security-Policy.
  `Config.dev_reload` forces it on or off. Nothing of it is in a release
  build. Pages compressed by `spider.gzip` get the script too.
- `devStep()` in Spider's `build.zig` and the `spider-dev-notify` build
  tool: the `dev` build step `spider dev` relies on. New apps have it; in an
  existing app add to `build.zig`:

  ```zig
  const spider_build = @import("spider");
  const dev = spider_build.devStep(b, spider_dep.artifact("spider-dev-notify"), exe, .{
      .assets = &.{"public/css/app.css"},
  });
  dev.step.dependOn(&css.step); // the Tailwind step, if the app has one
  ```

  `assets` are the files the page loads besides the binary, and
  `.templates = "src"` names the template directory. When a build changes
  only those (an edit to `src/styles.css` or to a template, which a Debug
  build reads from disk), `spider dev` keeps the app running and reloads
  the browser: about a second in an app of 378 templates, where a restart
  took four. A new, removed or renamed template restarts the app.
- `watchSources()` in Spider's `build.zig`: declares the files a build step
  reads, so `zig build --watch` reruns it when they change and skips it
  when they don't. Generated apps use it for Tailwind.

## [0.8.0] - 2026-10-08

### Breaking changes

- Spider needs the **Zig 0.17.0 release** (`minimum_zig_version` is
  `0.17.0`, for Spider and generated apps). The development build
  `0.17.0-dev.956` no longer builds it. In an app: install Zig 0.17.0, set
  `minimum_zig_version = "0.17.0"`, and rename what the standard library
  renamed (`builtin.mode == .Debug` is `.debug`; `uri.getHost(&buf)` is
  `std.Io.net.HostName.fromUri(uri, &buf)`).
- From this release Spider follows official Zig releases only. It stays on
  0.17.0 until 0.18.0 is released and no longer tracks Zig's development
  branch (README, "Zig Version Policy").
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

- Generated apps under `zig build --watch`: Tailwind never ran again after
  the first build, so a class first used in a template had no CSS, and an
  edit to `src/styles.css` did nothing. The Tailwind step now declares its
  sources (`watchSources`). It also no longer runs before the compiler but
  alongside it. In an existing app: add
  `spider_build.watchSources(b, css, "src", &.{ ".css", ".html", ".js" });`
  and replace `exe.step.dependOn(&css.step)` with
  `b.getInstallStep().dependOn(&css.step)`.
- A generated app with SQLite did not link in a release build
  (`zig build -Doptimize=ReleaseSmall`, which is what its Dockerfile runs):
  undefined `__ubsan_handle_*` symbols. The app's `build.zig` did not pass
  its optimize mode to Spider, so the bundled SQLite stayed in Debug. New
  apps pass `.optimize = optimize`; in an existing app, add that line to
  `b.dependency("spider", .{ ... })`.
- HTTP client (`spider.http_client`):
  - Every request crashed (segmentation fault) in an app built with
    incremental compilation, which is how `spider dev` builds: the client
    looked for proxy settings by walking libc's `environ` variable, which
    reads as a null pointer in such a build (Zig 0.17.0). It now calls
    `getenv()`.
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
