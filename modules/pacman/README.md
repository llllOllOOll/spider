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

Tests: `zig build test-pacman` from the repo root. Most of them call
httpbingo.org, so they need network access.
