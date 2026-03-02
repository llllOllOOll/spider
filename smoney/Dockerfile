FROM llllollooll/zig:master AS builder

WORKDIR /app

COPY . .

WORKDIR /app/smoney

RUN apt-get update && apt-get install -y --no-install-recommends libpq-dev
RUN zig build -Doptimize=ReleaseSmall

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends libpq5

WORKDIR /app

COPY --from=builder /app/smoney/data /app/data
COPY --from=builder /app/smoney/zig-out/bin/smoney .

CMD ["./smoney"]
