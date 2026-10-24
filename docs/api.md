# Drive & Save API

The contract between the iOS app, the backend and analytics. The source of truth is the Pydantic models in `backend/models/`; when the server is running, `/docs` shows the same contract interactively.

- **Base URL:** `https://drivesave.nuhylabs.com` (Vultr, [deployment guide](deploy.md)). For local development: `http://localhost:8000`.
- **Auth:** call `POST /users` once, keep the returned `token`, and send `Authorization: Bearer <token>` on every other request.
- **Times:** UTC, ISO 8601 with a timezone (`2026-10-24T20:01:00Z`). Times without a timezone are rejected.
- **Money:** USD. Every dollar figure is an estimate (`is_estimate: true`).
- **Errors:** always this shape, whatever the status code:

```json
{"error": {"code": "wrong_join_code", "message": "That join code does not match this crew"}}
```

Validation errors (422) use `code: "validation_error"` and add a `details` list with the field location of each problem.

## Endpoints

"Skeleton status" says what works today. Placeholder means the response has the final shape but uses fixed inputs until the real implementation lands.

| Method and path | Purpose | Skeleton status |
| --- | --- | --- |
| `GET /health` | Deployment check (no auth) | Done |
| `POST /users` | Create a user; returns `user_id` and `token` (no auth) | Done (in memory) |
| `GET /vehicles/years`, `/vehicles/makes`, `/vehicles/models`, `/vehicles/options` | Car picker menus, from fueleconomy.gov | Done |
| `GET /vehicles/{vehicle_id}` | Specs for one exact car | Done; no weight data yet |
| `PUT /users/me/vehicle` | Select the driver's car with `{"vehicle_id": ...}` | Done (in memory) |
| `GET /users/me/vehicle` | The selected car | Done (in memory) |
| `GET /users/{user_id}/progress` | Baseline, weekly trend, estimated savings (self only) | Done, using the $1-per-event placeholder pricing |
| `POST /trips` | Upload a trip summary and detected events | Done (in memory), idempotent |
| `GET /trips/{trip_id}/receipt` | Financial receipt and assumptions (owner only) | Done; flat $1 per event until the cost model lands |
| `GET /trips/{trip_id}/cost-input` | Exactly what the cost model receives for a trip (owner only) | Done |
| `POST /crews` | Create a crew; the creator joins automatically | Done (in memory) |
| `POST /crews/{crew_id}/join` | Join with `{"join_code": "..."}` | Done (in memory) |
| `GET /crews/{crew_id}` | Members, count, `active` (4+ members) | Done (in memory) |
| `GET /leaderboard` | Rivalry standings | Done; includes two labeled demo crews |

Not in the skeleton yet: `POST /trips/{id}/samples`, `POST /games` + `WS /ws/games/{code}`, `POST /admin/demo/reset`.

## Vehicles

The car picker walks fueleconomy.gov's menus: model year → make → model → option (engine and transmission). Each option is one exact car with its own `vehicle_id`, because MPG differs by engine and transmission.

1. `GET /vehicles/years` → `[2027, 2026, …]`
2. `GET /vehicles/makes?year=2020` → `["Acura", …, "Honda", …]`
3. `GET /vehicles/models?year=2020&make=Honda` → `["Accord", …, "Civic 4Dr", …]`
4. `GET /vehicles/options?year=2020&make=Honda&model=Civic 4Dr` → `[{"vehicle_id": 42150, "description": "Auto (variable gear ratios), 4 cyl, 1.5 L, Turbo"}, …]`
5. `PUT /users/me/vehicle` with `{"vehicle_id": 42150}` → the car's specs

- When a model has only one option, select it without asking the driver.
- Specs include MPG (city, highway, combined; MPGe for electric and hydrogen cars), fuel type, powertrain (hybrid, EV, …), size class, engine, transmission, drive and EPA's annual fuel cost. **fueleconomy.gov has no weight data, so `weight_lb` is null for now.**
- Each trip is priced with the car selected when it was uploaded, so changing cars later doesn't rewrite old receipts.
- If fueleconomy.gov is unreachable, these endpoints return `502` with `vehicle_data_unavailable`.

## Trips

`POST /trips` takes the trip summary and the events detected on the phone. The client never sends dollar amounts; the server prices every trip.

Example request: [`fixtures/sample-trip.json`](../fixtures/sample-trip.json).

| Field | Type | Rules |
| --- | --- | --- |
| `client_trip_id` | UUID | Generated on the phone. Re-uploading the same id returns the original trip with `200` and `duplicate: true` |
| `started_at`, `ended_at` | datetime | `ended_at` must be after `started_at` |
| `distance_mi` | number | Greater than 0, at most 1000 |
| `avg_speed_mph` | number | 0 to 120 |
| `events[]` | list | Each event must fall inside the trip window; at most 10 events per minute |
| `events[].type` | string | `harsh_brake`, `rapid_accel` or `sharp_turn` |
| `events[].peak_g` | number | Peak acceleration in g, above 0 and at most 2.0: forward/backward for `harsh_brake` and `rapid_accel`, sideways for `sharp_turn` |
| `events[].speed_before_mph`, `speed_after_mph` | number | 0 to 120 |
| `events[].duration_s` | number, optional | How long the event lasted, in seconds (up to 60). The cost model uses it for mean acceleration |
| `events[].heading_change_deg` | number, optional | How far the car turned, 0 to 360 degrees. Send it for `sharp_turn` |
| `events[].lat`, `lng` | number, optional | Valid coordinates |

Response (`201`, or `200` for a duplicate):

```json
{"trip_id": "51f08747-…", "receipt_url": "/trips/51f08747-…/receipt", "duplicate": false}
```

## Receipt

Example response: [`fixtures/sample-receipt.json`](../fixtures/sample-receipt.json). The iOS app can bundle this file as its offline fallback.

**Pricing is a placeholder: every harsh event (`harsh_brake`, `rapid_accel`, `sharp_turn`) costs a flat $1.** A teammate is building the real cost model; what it receives is described in [`docs/cost-model.md`](cost-model.md). When it lands, the amounts change and fields may be added (for example fuel cost or a yearly projection), but the fields below keep their meaning.

- `events[].cost_usd`: what each event cost ($1.00 each for now).
- `avoidable_cost_usd`: the sum of the event costs for the trip.
- `cost_model`: which model produced the amounts; `flat_per_event` for now.
- `assumptions[]`: every input with its `source_url` and `as_of` date. For now it holds one entry, `cost_per_event` = 1.0. `is_estimate: true` marks team assumptions rather than published figures; show those as "estimate" in the UI.

## Crews and leaderboard

- A crew is **active** once it has 4 or more members. Only active crews are ranked.
- `join_code` is 6 characters (no 0/O or 1/I), case-insensitive, and only returned to members. Put `crew_id` and `join_code` in the QR code.
- `GET /leaderboard?scope=crews` ranks crews against each other. `GET /leaderboard?scope=members&crew_id=...` ranks the members of one crew (members only).
- `improvement_pct` = (baseline − this week's waste per mile) ÷ baseline × 100. The baseline is a driver's first 3 trips.
- Each standing has a generic `id`: the `crew_id` for `scope=crews`, the `user_id` for `scope=members`.
- Standings with `is_demo: true` are demo data. Always label them in the UI.

## Notes for the skeleton

- Data lives in memory: **restarting the server deletes all users, crews and trips.** Call `POST /users` again after a restart.
- Every harsh event costs a flat $1 until the real cost model lands, so progress and leaderboard amounts are placeholders too.
