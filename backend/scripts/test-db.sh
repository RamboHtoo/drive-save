#!/usr/bin/env bash
# Starts a local TimescaleDB in Docker with the shared schema, for tests and local runs.
#   ./scripts/test-db.sh            start (or reuse) the container and apply the schema
#   ./scripts/test-db.sh --reset    recreate it from scratch
# Then: export TEST_DATABASE_URL=postgresql://postgres:test@localhost:55432/postgres
set -euo pipefail
cd "$(dirname "$0")/../.."

NAME=drivesave-testdb
if [[ "${1:-}" == "--reset" ]]; then docker rm -f "$NAME" >/dev/null 2>&1 || true; fi

if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --name "$NAME" -p 55432:5432 -e POSTGRES_PASSWORD=test timescale/timescaledb:latest-pg17 >/dev/null
  until docker exec "$NAME" pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
  sleep 2  # the image restarts Postgres once after initializing
  until docker exec "$NAME" pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
fi

for file in analytics/schema.sql analytics/queries.sql backend/db/002_event_details.sql; do
  docker exec -i "$NAME" psql -q -U postgres -v ON_ERROR_STOP=1 < "$file" >/dev/null
done
# Tests truncate tables between runs, so keep the aggregate purely real-time (no background refresh).
docker exec "$NAME" psql -q -U postgres -c \
  "SELECT remove_continuous_aggregate_policy('public.daily_user_metrics', if_exists => true);" >/dev/null

echo "TimescaleDB ready: postgresql://postgres:test@localhost:55432/postgres"
