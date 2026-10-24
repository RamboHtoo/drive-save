# Drive & Save API

The contract between the iOS app, the backend and analytics. The source of truth is the Pydantic models in `backend/models/`; when the server is running, `/docs` shows the same contract interactively.

- **Base URL (local):** `http://localhost:8000`. The Vultr HTTPS URL will be added here once it's deployed.
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
| `PUT /users/me/vehicle` | Register the car and its MPG | Manual MPG works; fueleconomy.gov lookup is a placeholder |
| `GET /users/{user_id}/progress` | Baseline, weekly trend, estimated savings (self only) | Done, using placeholder pricing |
| `POST /trips` | Upload a trip summary and detected events | Done (in memory), idempotent |
| `GET /trips/{trip_id}/receipt` | Financial receipt and assumptions (owner only) | Placeholder pricing until `analytics/finance.py` |
| `POST /crews` | Create a crew; the creator joins automatically | Done (in memory) |
| `POST /crews/{crew_id}/join` | Join with `{"join_code": "..."}` | Done (in memory) |
| `GET /crews/{crew_id}` | Members, count, `active` (4+ members) | Done (in memory) |
| `GET /leaderboard` | Rivalry standings | Done; includes two labeled demo crews |

Not in the skeleton yet: `POST /trips/{id}/samples`, `POST /games` + `WS /ws/games/{code}`, `POST /admin/demo/reset`.

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
| `events[].peak_g` | number | Greater than 0, at most 2.0 |
| `events[].speed_before_mph`, `speed_after_mph` | number | 0 to 120 |
| `events[].lat`, `lng` | number, optional | Valid coordinates |

Response (`201`, or `200` for a duplicate):

```json
{"trip_id": "51f08747-…", "receipt_url": "/trips/51f08747-…/receipt", "duplicate": false}
```

## Receipt

Example response: [`fixtures/sample-receipt.json`](../fixtures/sample-receipt.json). The iOS app can bundle this file as its offline fallback.

- `fuel_cost_usd`: what the fuel for this trip cost.
- `avoidable_fuel_usd`: the part of that cost caused by aggressive driving.
- `events[].cost_usd`: each event's share, split by kinetic energy (v₁² − v₂²).
- `projection.yearly_usd`: this trip's waste per mile × yearly miles.
- `assumptions[]`: every input with its `source_url` and `as_of` date. `is_estimate: true` marks team assumptions rather than published figures; show those as "estimate" in the UI.

## Crews and leaderboard

- A crew is **active** once it has 4 or more members. Only active crews are ranked.
- `join_code` is 6 characters (no 0/O or 1/I), case-insensitive, and only returned to members. Put `crew_id` and `join_code` in the QR code.
- `GET /leaderboard?scope=crews` ranks crews against each other. `GET /leaderboard?scope=members&crew_id=...` ranks the members of one crew (members only).
- `improvement_pct` = (baseline − this week's waste per mile) ÷ baseline × 100. The baseline is a driver's first 3 trips.
- Each standing has a generic `id`: the `crew_id` for `scope=crews`, the `user_id` for `scope=members`.
- Standings with `is_demo: true` are demo data. Always label them in the UI.

## Notes for the skeleton

- Data lives in memory: **restarting the server deletes all users, crews and trips.** Call `POST /users` again after a restart.
- Placeholder pricing uses 25 mpg city / 32 mpg highway until a vehicle is registered, and the EIA US average gas price ($4.284/gal, week of Oct 19, 2026).
