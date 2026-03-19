#!/bin/bash
set -e

echo "Starting test database..."
docker compose -f docker-compose.test.yml up -d

echo "Waiting for postgres..."
sleep 3

echo "Running tests..."
POSTGRES_HOST=localhost \
POSTGRES_PORT=5455 \
POSTGRES_DB=smoney_test \
POSTGRES_USER=postgres \
POSTGRES_PASSWORD=postgres \
zig test src/pg.zig -lpq -lc

echo "Stopping test database..."
docker compose -f docker-compose.test.yml down

echo "Done!"
