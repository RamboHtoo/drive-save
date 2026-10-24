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
| `services/scoring.py` | Placeholder trip pricing and progress math; replaced by `analytics/finance.py` |
| `services/demo.py` | Labeled demo crews for the leaderboard |
| `store.py` | Temporary in-memory storage; replaced by Tiger Data |

## Next steps

1. Tiger Data: replace `store.py` with real tables (`DATABASE_URL`).
2. Pricing: call `analytics/finance.py` from `services/scoring.py`.
3. Vehicle lookup on fueleconomy.gov.
4. Live game: `POST /games` and `WS /ws/games/{code}`.
5. Deploy to Vultr (Docker Compose + Caddy for HTTPS).
