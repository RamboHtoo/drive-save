# Drive & Save backend

FastAPI service for trips, receipts, crews and leaderboards, storing everything in Tiger Data (Postgres + TimescaleDB). API contract: [`docs/api.md`](../docs/api.md).

## Run locally

Requires Python 3.12 and Docker (for a local TimescaleDB with the shared schema).

```bash
cd backend
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
./scripts/test-db.sh                     # local TimescaleDB on port 55432 with analytics/schema.sql applied
cp .env.example .env                     # then set DATABASE_URL=postgresql://postgres:test@localhost:55432/postgres
PYTHONPATH=.. uvicorn main:app --reload --env-file .env   # .. puts the fuel model (drive_save_model/) on the path
```

Then open http://localhost:8000/docs to try every endpoint in the browser.

To reach the server from an iPhone on the same Wi-Fi, start it with `--host 0.0.0.0` and use your Mac's IP address. iOS blocks plain HTTP by default, so the app needs `NSAllowsLocalNetworking` in its App Transport Security settings, or use the deployed HTTPS URL instead.

## Test

```bash
./scripts/test-db.sh
pytest
```

The tests run against the local TimescaleDB (empty tables before each test). They upload [`fixtures/sample-trip.json`](../fixtures/sample-trip.json), check every endpoint's response shape and error format, and check the database rules from [`docs/database-setup.md`](../docs/database-setup.md): baseline slots, metrics rows, signed savings and atomic uploads. Point `TEST_DATABASE_URL` at another throwaway database to use that instead. Never point it at Tiger Cloud: the tests empty every table.

## Layout

| Path | What it does |
| --- | --- |
| `main.py` | App setup, database pool lifecycle, CORS, routers, `/health` |
| `config.py` | Environment variables |
| `db.py` | asyncpg connection pool for Tiger Data |
| `repo.py` | Every database query: users, crews, trip uploads and scoring, receipts, progress, leaderboard |
| `errors.py` | The shared `{"error": {...}}` response format |
| `auth.py` | Bearer tokens (only hashes are stored) |
| `models/` | Pydantic request/response schemas: the API contract |
| `routes/` | One file per resource: users, trips, crews, leaderboard |
| `models/cost_model.py` | What the cost model receives and returns. See [`docs/cost-model.md`](../docs/cost-model.md) |
| `services/cost_model.py` | Builds the cost model input and prices the trip with the data teammate's Mazda5 model (`drive_save_model/`). See [`docs/cost-model.md`](../docs/cost-model.md) |
| `db/002_event_details.sql` | Adds the sharp-turn angle (`heading_change_deg`) the backend stores to the shared schema |
| `db/app_role.sql` | Least-privilege database role for the running app |
| `scripts/test-db.sh` | Starts the local TimescaleDB used by tests and local runs |
| `scripts/setup-tiger.sh` | Backend setup on Tiger Cloud: checks the schema version, adds the event column, creates the app role and sets the server's `DATABASE_URL`. See [`docs/deploy.md`](../docs/deploy.md) |
| `Dockerfile`, `docker-compose.yml`, `Caddyfile` | Production stack: the API behind Caddy with automatic HTTPS. See [`docs/deploy.md`](../docs/deploy.md) |

The tables and analytics functions (`analytics/schema.sql`, `analytics/queries.sql`) belong to the data teammate; see [`docs/database-setup.md`](../docs/database-setup.md). They're at schema version 4, where crews are called leagues (`leagues`, `league_members`, `league_id`); the API keeps the crew names.

## Next steps

1. Live game: `POST /games` and `WS /ws/games/{code}`.
2. Demo data: load `analytics/demo_seed.sql` and add a demo reset.
