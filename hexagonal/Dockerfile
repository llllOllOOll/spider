FROM archlinux:latest
RUN pacman -Sy --noconfirm postgresql-libs
WORKDIR /app
COPY zig-out/bin/hexagonal /app/hexagonal
RUN chmod +x /app/hexagonal
ENV HOST=0.0.0.0
ENV PORT=8081
ENV DATABASE_URL=postgres://spider:spider@db:5432/spider
EXPOSE 8081
CMD ["/app/hexagonal"]
