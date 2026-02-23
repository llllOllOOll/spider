FROM llllollooll/zig:master AS builder

WORKDIR /app

COPY . .

WORKDIR /app/hello

RUN apt-get update && apt-get install -y --no-install-recommends libpq-dev

RUN zig build -Doptimize=ReleaseSmall

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends libpq5

WORKDIR /app

COPY --from=builder /app/hello/zig-out/bin/app .

CMD ["./app"]
