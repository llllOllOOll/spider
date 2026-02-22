FROM zig-test AS builder

WORKDIR /app

COPY hello/ .
COPY spider/ ./spider/
COPY spider_pg/ ./spider_pg/
RUN zig build

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /app/zig-out/bin/app /app/

CMD ["./app"]
