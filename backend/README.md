# Drive & Save backend

FastAPI service for trips, receipts, crews and leaderboards. API contract: [`docs/api.md`](../docs/api.md).

## Run locally

Requires Python 3.12.

```bash
cd backend
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
cp .env.example .env
uvicorn main:app --reload --env-file .env
```

Then open http://localhost:8000/docs to try every endpoint in the browser.

To reach the server from an iPhone on the same Wi-Fi, start it with `--host 0.0.0.0` and use your Mac's IP address. iOS blocks plain HTTP by default, so the app needs `NSAllowsLocalNetworking` in its App Transport Security settings until we deploy to Vultr with HTTPS.

## Test

```bash
pytest
```

The tests upload [`fixtures/sample-trip.json`](../fixtures/sample-trip.json) and check every endpoint's response shape and error format.

## Layout

| Path | What it does |
| --- | --- |
| `main.py` | App setup, CORS, routers, `/health` |
| `config.py` | Environment variables |
| `errors.py` | The shared `{"error": {...}}` response format |
| `auth.py` | Bearer tokens (only hashes are stored) |
| `models/` | Pydantic request/response schemas: the API contract |
| `routes/` | One file per resource: users, trips, crews, leaderboard |
| `models/cost_model.py` | What the cost model receives and returns. See [`docs/cost-model.md`](../docs/cost-model.md) |
| `services/cost_model.py` | Builds the cost model input and calls the model. Placeholder: $1 per event until the real model lands |
| `services/scoring.py` | Baselines, improvement and estimated savings per driver |
| `services/demo.py` | Labeled demo crews for the leaderboard |
| `store.py` | Temporary in-memory storage; replaced by Tiger Data |
| `Dockerfile`, `docker-compose.yml`, `Caddyfile` | Production stack: the API behind Caddy with automatic HTTPS. See [`docs/deploy.md`](../docs/deploy.md) |

## Next steps

1. Tiger Data: replace `store.py` with real tables (`DATABASE_URL`).
2. Cost model: replace the flat $1 per event in `services/cost_model.py` with the teammate's model.
3. Live game: `POST /games` and `WS /ws/games/{code}`.
4. Deploy to Vultr: follow [`docs/deploy.md`](../docs/deploy.md).
