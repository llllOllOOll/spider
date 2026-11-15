# 0001. zio is the default I/O backend

- **Status:** Proposed
- **Date:** 2026-11-15
- **Applies to:** Spider 0.14

## Context

Spider builds with one of two I/O backends, chosen with `-Dio_backend`:

- **`threaded`** (the default until 0.14): each worker thread accepts
  connections and hands each one to `std.Io.Group.concurrent`. On
  `std.Io.Threaded` that is one OS thread per open connection, for as long
  as the connection lives; with keep-alive, an idle connection still holds
  its thread.
- **`zio`**: fibers on an event loop. A few threads (about one per core)
  serve any number of connections; a connection waiting for the network
  costs a fiber, not a thread.

`std.Io.Threaded` adds a new thread to its pool when every thread is busy,
and the thread stays in the pool for good: its documentation says it is
"permanently added to the pool" (Zig 0.17.0, `lib/std/Io/Threaded.zig`,
the `async_limit` / `concurrent_limit` options; `groupConcurrent` and
`worker` show the shared run queue the pool threads wait on). That design
fits short tasks. A web server's connections are long ones.

We measured a storefront app (a home page, a sorted and paginated list, a
product page) in release builds on a 12-thread machine, with `oha` on
keep-alive connections:

| Load | `threaded` | `zio` |
|---|---|---|
| Up to 256 connections | 15–115 k req/s, p99 0.06–14 ms | not measured point by point |
| 1024 connections, fresh server, product page | 69.7 k req/s | 62.5 k req/s |
| 1024 connections, the same page again | **2.7 k req/s, p99 5.1 s** | 62.5 k req/s |
| Memory after a 1024-connection run | **~320 MiB**, kept after every connection closed | 60–76 MiB |
| 10 minutes, 255 connections, three pages at once | ~53 k req/s, 100 % ok, no growth | ~55 k req/s, 100 % ok, no growth |

After a run at around a thousand connections the pool holds about that
many sleeping threads (their stacks are the memory that stays), and the
next wave of connections waits in the pool's queue until another
connection closes. The 0.12.1 release has the same behaviour, worse on the
first run (1.5 k req/s). The second row repeated with zio v0.20.1 and
5-second runs: zio 58.2 / 60.1 / 54.9 k req/s with 76 MiB; threaded
58.5 k, then 0.6 k req/s with a 4 s p99, and 318 MiB.

zio already ran in production behind Docker for months before this
decision, forced to epoll on Linux: Docker's default seccomp profile
refuses `io_uring_setup`, and a minimal zio reproduction in a container
crashed within seconds with io_uring and ran clean with epoll.

## Decision

`zio` is the default backend (`-Dio_backend` and what `spider new`
writes). On Linux it uses epoll; on macOS and the BSDs kqueue, on Windows
IOCP (zio's own defaults). zio is pinned to its v0.20.1 release.

`threaded` stays available with `-Dio_backend=threaded` and keeps being
tested in CI on both backends.

## Alternatives considered

- **Keep `threaded` as the default and document its limit.** The limit is
  hit by an ordinary traffic spike, and the memory never comes back: a
  default should not fail that way.
- **Fix `threaded` with Spider's own threads**: one thread per connection
  that ends when the connection closes, plus a cap on connections. It
  removes the memory that stays and the queue wait, but an idle keep-alive
  connection still costs a thread. Worth doing for `threaded` itself (see
  Consequences), not a reason to keep it as the default.
- **A watcher for idle connections plus a fixed pool of threads** (epoll
  or kqueue tells which connection has data; a fixed set of threads serves
  the requests). It scales like an event loop, but it is a second event
  loop to write and maintain next to zio.
- **Zig's own evented I/O (`std.Io.Evented`).** It is the same model as
  zio and would remove the dependency, but in Zig 0.17 it is still
  experimental: on Linux it is io_uring only (refused under Docker's
  default seccomp profile) and parts of its networking are not
  implemented yet.

## Consequences

- Apps get a server that holds a thousand connections at once with
  steady latency and ~70 MiB instead of ~320 MiB.
- Every app now fetches and builds zio (a lazy dependency, fetched on the
  first build). Spider follows zio's releases; a zio bug is now a Spider
  bug. v0.20.1 is pinned because it fixes a thread leak in zio's own pool.
- Handlers run on several threads with either backend: shared state still
  needs guarding, as before.
- An app that sets `.io_backend = .threaded` in its `build.zig` keeps it;
  one that sets nothing moves to zio.
- `threaded` keeps its limit for now, documented where the backend is
  chosen. Spider writes its own connection handling (a thread per
  connection that ends when the connection closes, plus a cap on
  connections) only if one of these happens: zio has a serious problem or
  is no longer maintained, or Spider needs to build without an outside
  dependency.
- Revisit this decision when Zig's evented I/O is complete and works under
  the default container profile: it could replace zio.

## References

- Zig 0.17.0 standard library, `lib/std/Io/Threaded.zig`: the pool options
  (threads "permanently added to the pool"), `groupConcurrent` and
  `worker`.
- Spider: `src/core/app.zig` (`workerLoop`, `listenThreaded`,
  `listenZio`), `build.zig` (`-Dio_backend`, zio forced to epoll on Linux).
- zio v0.20.1 (`lalinsky/zio`, commit c0a6b58), including the fix for its
  pool's thread leak (issue #879, pull request #881).
- Zig's devlog on the state of `std.Io.Evented` (io_uring and Grand
  Central Dispatch implementations described as experimental).
- The measurements above: release builds, `oha` with keep-alive
  connections, 15-second points (the 5-second repeat is marked as such),
  10-minute long runs, server memory read from `/proc/<pid>/status`.
