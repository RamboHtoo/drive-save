# Drive & Save

iOS app that turns driving habits into savings and friendly competition.

Drivers record trips on their iPhone. The backend finds harsh events (hard braking,
rapid acceleration, sharp turns), prices the wasted fuel as the driver's own car, and
returns a receipt. Drivers compete individually inside private leagues, ranked by
this week's estimated avoidable fuel cost: lowest cost ranks first.

Fuel estimates come from an experimental model. Independent laboratory validation
and real-world accuracy checks are pending, so every receipt is labeled as an estimate.

## Status (2026-10-25)

- `main` is the HackPSU final integration of the `backend`, `ios` and `analytics`
  branches. The [release report](docs/release-hackpsu-final.md) lists the exact
  commits merged, every check that ran and the deployment prerequisites.
- The live API at `https://drivesave.nuhylabs.com` runs `main`, including
  `GET /leaderboard/costs`. Before the redeploy, `backend/db/004_league_demo.sql` was
  applied to Tiger and `drivesave_app` was granted read-only access to the
  `drivesave_demo` schema (no insert, update or delete). `backend/db/app_role.sql`
  does not include that grant yet, so a fresh Tiger setup needs it added by hand.
- The six-player league showcase is local only. `drivesave_demo` is empty in
  production and demo writes stay off.
- Not yet verified: on-road GPS quality on a physical iPhone, and a full
  recording → deployed server → receipt round trip on a device.

## Repository layout

| Path | What it is | Guide |
| --- | --- | --- |
| `ios/` | Native SwiftUI app (iOS 17+): trip recording, receipts, leagues, vehicle picker | [ios/README.md](ios/README.md) |
| `backend/` | FastAPI service on Vultr: users, vehicles, trips, receipts, crews, leaderboards | [backend/README.md](backend/README.md) |
| `drive_save_model/` | Python fuel model (`vehicle-fuel-v2`) that prices each trip as the driver's car | [docs/fuel-model.md](docs/fuel-model.md) |
| `analytics/` | Tiger Data (Postgres + TimescaleDB) schema v4, analytics queries, demo seed | [docs/database-setup.md](docs/database-setup.md) |
| `vehicle/` | EPA Test Car List files (2007–2026) behind the car picker | [docs/vehicle-catalog.md](docs/vehicle-catalog.md) |
| `fixtures/` | Sample trip, vehicle, cost input and receipt shared by tests and docs | |
| `tests/` | Fuel model tests and the PostgreSQL regression suite | |
| `scripts/` | Model data fetch and iOS payload fixture tools | |
| `docs/` | API contract, product plan, deployment and design notes | See below |

## How a trip flows

1. The iPhone records GPS speed and motion, detects candidate events, and uploads the
   trip with `POST /trips`. Coordinates never leave the phone.
2. The backend scores only the stretches with good GPS coverage
   ([GPS scoring windows](docs/gps-scoring-window.md)) and prices the trip with
   `drive_save_model` using the driver's car from the EPA list
   ([cost model](docs/cost-model.md)).
3. The result is stored once in Tiger Data. The app reads it back as a receipt with
   `GET /trips/{trip_id}/receipt`.
4. `GET /leaderboard/costs` ranks league members by the sum of their scored, recorded
   trips' estimated avoidable fuel cost in the current UTC week (Monday to Monday).
   Lower is better, ties share a rank, and drivers with no scored trips stay unranked.
   A league needs at least four real members.

`GET /leaderboard` is kept for older clients and ranks by improvement against each
driver's first-three-trip baseline. `GET /leaderboard/demo` is the showcase that
mixes players labeled **Synthetic demo** with the presenter's real results. Seeding
it stays off unless `DRIVESAVE_ENABLE_LEAGUE_DEMO_WRITE=1`.

## Run it

- **iOS:** open `ios/DriveAndSave.xcodeproj`, pick the **DriveAndSave** scheme and a
  simulator, then ⌘R. Details and test commands: [ios/README.md](ios/README.md).
- **Backend:** local TimescaleDB with Docker, then uvicorn. Steps:
  [backend/README.md](backend/README.md). Production deploy: [docs/deploy.md](docs/deploy.md).
- **Fuel model:** with Python 3.12 dependencies installed as described in the
  [fuel model guide](docs/fuel-model.md):

  ```sh
  .venv/bin/python -m drive_save_model demo
  .venv/bin/python -m drive_save_model validate
  .venv/bin/python -m pytest -q
  ```

  `validate` exits 2 while its scientific release gate is unmet. It does not treat
  simulated cycle results as independent measured fuel accuracy.

- **SQL regression suite** (needs local PostgreSQL tools):

  ```sh
  python3 tests/run_sql_tests.py --postgres-only
  ```

  Add `--with-model` and use `.venv/bin/python` to also test the
  model → asyncpg → leaderboard flow. The suite checks schema constraints, individual
  rankings and migration data preservation. It uses an ordinary view in place of
  Timescale's continuous aggregate, so Timescale policy behavior still needs a cloud
  check. Files in `tests/fixtures/v1/` are historical migration snapshots, not
  deployment scripts; deploy from `analytics/`.

Never point any test suite at Tiger Cloud: the backend tests empty every table.

## Documentation

| Doc | Covers |
| --- | --- |
| [Product plan](docs/product-plan.md) | Individual competition inside leagues |
| [API contract](docs/api.md) | Every endpoint, request and response |
| [League API contract](docs/league-api.md) | League routes between the backend and the app |
| [Database setup](docs/database-setup.md) | Tiger Data schema, migrations and analytics |
| [Fuel model](docs/fuel-model.md) | How the estimator works and its validation limits |
| [Cost model](docs/cost-model.md) | How the backend prices a trip with the fuel model |
| [Vehicle catalog](docs/vehicle-catalog.md) | EPA car list and per-car fuel model parameters |
| [GPS scoring windows](docs/gps-scoring-window.md) | Which parts of a trip get scored |
| [Deployment](docs/deploy.md) | Vultr + Docker + Caddy, connecting Tiger Data |
| [HackPSU release report](docs/release-hackpsu-final.md) | Integrated commits, validation results, deployment blockers |
| [iOS backend integration](ios/Docs/BackendIntegration.md) | How the app uses the API |
