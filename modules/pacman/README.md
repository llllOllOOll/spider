# pacman

Spider's HTTP client (`spider.http_client`): a Fetch-style wrapper over
`std.http.Client`, used by the auth providers, Web Push, mail and R2.

Brought into the monorepo from https://github.com/llllOllOOll/pacman
(`src/` at 1c68d77). The standalone repository also carries
`vendor/zig-lib-patched`, a patched copy of the Zig stdlib for its own test
step; it is not needed here and was left out.

SOCKS5 proxying (`src/proxy.zig`) calls `std.http.Client.adoptTunneledStream`,
which only exists in a Zig whose `lib/std/http/Client.zig` has pacman's
patch applied.

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

## Tests

- `zig build test-pacman-local` — against scripted local servers
  (`local_test.zig`): timeouts, cut bodies, oversized responses. No network.
  Add `-Dio_backend=zio` to run them on the zio backend.
- `zig build test-pacman` — most of these call httpbingo.org, so they need
  network access (and one of them asserts on that server's latency).
