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
| `PUT /users/me/vehicle` | Send the driver's car data from the EPA dataset; stored as-is | Done (in memory) |
| `GET /users/me/vehicle` | The car data, exactly as sent | Done (in memory) |
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

The app lets the driver pick their car from the EPA dataset and sends that car's data with `PUT /users/me/vehicle`. The body is a JSON object with any fields. The backend doesn't read or change them: it stores the object and passes it unchanged to the cost model with every trip uploaded afterwards. Field names are agreed between the app and the data teammate.

Example body: [`fixtures/sample-vehicle.json`](../fixtures/sample-vehicle.json), built from a real row of the EPA Test Car List.

- The body must be a JSON object with 1 to 200 fields, under 20 KB.
- Each trip is priced with the car data sent before it was uploaded, so changing cars later doesn't rewrite old receipts.
- `GET /users/me/vehicle` returns the object exactly as sent, or `404` with `vehicle_not_set`.

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
| `events[].speed_trace` | list, **required** | Speeds around the event, oldest first: `[{"t_s": -10, "speed_mph": 34.5}, …, {"t_s": 10, "speed_mph": 22.5}]`. `t_s` is seconds from the event's `ts` (negative = before). Needs at least one sample before and one after the event, in increasing time order; up to 241 samples within ±60 s |
| `events[].lat`, `lng` | number, optional | Valid coordinates |

**Recording the speed trace:** keep the last 10 seconds of GPS speed (about one reading per second) in a rolling buffer. When an event is detected, attach that buffer, keep recording for 10 more seconds, and attach those readings too. The cost model uses the trace to compare each event with a smooth alternative.

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
