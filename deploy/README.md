# Production Deployment

Spider runs as an HTTP server. For HTTPS in production, use a reverse proxy for TLS termination.

## Architecture

```
                    ┌─────────────┐
                    │   nginx     │
                    │  (TLS 443)  │
                    └──────┬──────┘
                           │ proxy
                    ┌──────▼──────┐
                    │  Spider     │
                    │ (localhost: │
                    │   8080)     │
                    └─────────────┘
```

This is the same pattern used by Go, Rust, and Node.js servers in production.

## Option 1: nginx

```bash
# Copy config
sudo cp deploy/nginx.conf /etc/nginx/nginx.conf

# Generate SSL certs (or use Let's Encrypt)
sudo certbot certonly --standalone -d example.com

# Start nginx
sudo nginx -t && sudo nginx

# Run spider
zig build run -Doptimize=ReleaseFast
```

## Option 2: Caddy (simpler)

```bash
# Install Caddy
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install caddy

# Run spider first (on port 8080)
zig build run -Doptimize=ReleaseFast &

# Start Caddy
cd deploy && caddy adapt --adapter caddyfile | sudo tee /etc/caddy/Caddyfile
sudo systemctl start caddy
```

## Local Development

```bash
# Just run spider directly (HTTP only)
zig build run -Doptimize=ReleaseFast
```

## Health Check

```bash
curl http://localhost:8080/health
# {"status":"ok","version":"0.1.0"}
```

## Native TLS (Future)

See TODO in `src/server.zig` for native TLS support in v0.3.0.
