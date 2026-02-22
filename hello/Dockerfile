FROM llllollooll/zig:master AS builder

WORKDIR /app

COPY . .

WORKDIR /app/hello

RUN zig build -Doptimize=ReleaseSmall -Dtarget=x86_64-linux-musl

FROM scratch

WORKDIR /app

COPY --from=builder /app/hello/zig-out/bin/app .

CMD ["./app"]
