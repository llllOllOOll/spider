# std_http — pacman's copy of Zig's HTTP client

`Client.zig` is Zig 0.17.0's `lib/std/http/Client.zig` (MIT, `LICENSE`) with
two changes. pacman imports it instead of `std.http.Client`; everything
else (`std.http.Reader`, `std.crypto.tls`, …) still comes from the standard
library. Nobody has to patch their Zig to build Spider.

## Why it exists

Zig 0.17.0 cannot put TLS on top of a tunnel:

- **https through an HTTP proxy.** `connectProxied` returns the CONNECT
  tunnel as a plain connection, so the request goes out unencrypted and the
  target rejects it.
- **SOCKS5.** There is no way to hand the client a stream that is already
  connected. The types that would allow it (`Connection.Plain`,
  `Connection.Tls`) are private, so it cannot be done from outside the
  file either.

## What differs from the standard library

1. The header comment, and `@import("../std.zig")` became `@import("std")`.
2. `connectProxied` takes the target's `protocol`, does the TLS handshake
   after CONNECT when it is `.tls`, and only releases the connection in its
   `errdefer` if it was not already destroyed.
3. `adoptTunneledStream` (new, public): makes a pooled connection from an
   already tunneled stream. `src/proxy.zig` calls it after the SOCKS5
   handshake.
4. `ensureCertBundleLoaded` (new): the CA bundle loading that `request()`
   did inline, so `adoptTunneledStream` can run before the first request.

To see the exact difference:

```sh
diff -u "$(dirname "$(which zig)")/lib/std/http/Client.zig" modules/pacman/src/std_http/Client.zig
```

## On a new Zig release

Check whether the standard library gained both fixes. If it did, delete
this directory and point `HttpClient` in `src/*.zig` back at
`std.http.Client`. If not, copy the new `Client.zig` here and reapply the
changes above.

## Checking it

`zig build test-pacman-local` needs no network. The proxy paths only run
against a real proxy:

```sh
PACMAN_TEST_SOCKS5_PROXY=socks5h://127.0.0.1:1080 \
PACMAN_TEST_HTTP_PROXY=http://127.0.0.1:8899 zig build test-pacman
```
