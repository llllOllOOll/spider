# pacman

Spider's HTTP client (`spider.http_client`): a Fetch-style wrapper over
Zig's HTTP client, used by the auth providers, Web Push, mail and R2.

Brought into the monorepo from https://github.com/llllOllOOll/pacman
(`src/` at 1c68d77). The standalone repository also carries
`vendor/zig-lib-patched`, a patched copy of the Zig stdlib for its own test
step; it is not needed here and was left out.

It builds with an unmodified Zig. The standard library's client cannot do
TLS over a tunnel (https through an HTTP proxy, anything through SOCKS5),
so pacman uses its own copy of that one file with the fix:
`src/std_http/Client.zig`. `src/std_http/README.md` says what differs and
when to delete it.

## Limits on a request

Every call takes `FetchOptions`. Three of its fields bound what a remote
server can do to the caller:

- `timeout_ms` — deadline for the whole request (connect, TLS, send, wait,
  read the body). When it passes the call fails with `error.Timeout` and the
  connection is closed. `0` (the default) means no deadline: the call waits
  for as long as the server takes. **Set it** on anything that talks to a
  server you don't control.
- `max_response_bytes` — largest body accepted, counted after decompression.
  Default 64 MiB (`default_max_response_bytes`); over it the call fails with
  `error.ResponseTooLarge`. Raise it for a known-large download.
- A body that stops before it is complete — a chunked response that breaks
  off, or fewer bytes than `Content-Length` promised — fails with
  `error.HttpBodyCutShort` instead of returning the part that arrived.

A request that fails or times out closes its connection; a persistent
`Client` never reuses it.

Not supported: following redirects (a 3xx with a `Location` fails with
`error.HttpRedirectLocationOversize`) and streaming the response body.

## Known gaps

Open items from the timeout / size-limit work (2026-10). None is fixed yet.

- **Cancelation is not tested over TLS.** The scripted servers in
  `local_test.zig` speak plain HTTP. That a deadline interrupts a request
  blocked inside a TLS read, on both backends, is assumed from the plain
  case, not measured. Needs a scripted TLS server.
- **The 64 MiB default can break large R2 downloads.** `modules/r2` calls
  this client with the default options, so an object larger than
  `default_max_response_bytes` now fails with `error.ResponseTooLarge`. The
  size of the objects applications actually store was not measured. Before
  an application takes this version: measure, and have `modules/r2` pass a
  limit that fits (or stream the download).
- **`modules/r2` and every other caller still pass no `timeout_ms`.** The
  deadline exists but is opt-in; nothing got one by default.
- **A test asserts on httpbingo's latency.** "concurrent async requests with
  Client methods" (`src/root.zig`) expects two 1 s requests to finish in
  under 2.5 s against a public server; it failed once in seven runs. It
  should leave the default network suite, or become a local scripted test.
- **A body with no declared length cannot be checked for truncation.** When
  the response has neither `Content-Length` nor chunked encoding, the body
  is whatever arrives until the server closes; a connection dropped midway
  is indistinguishable from the end.

## Tests

- `zig build test-pacman-local` — against scripted local servers
  (`local_test.zig`): timeouts, cut bodies, oversized responses. No network.
  Add `-Dio_backend=zio` to run them on the zio backend.
- `zig build test-pacman` — most of these call httpbingo.org, so they need
  network access (and one of them asserts on that server's latency).
