FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libpq-dev && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY zig-out/bin/hexagonal /app/hexagonal
RUN chmod +x /app/hexagonal

ENV HOST=0.0.0.0
ENV PORT=8081
ENV DATABASE_URL=postgres://spider:spider@db:5432/spider

EXPOSE 8081

CMD ["/app/hexagonal"]
