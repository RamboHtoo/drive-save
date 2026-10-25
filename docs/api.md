# Drive & Save API

The contract between the iOS app, the backend and analytics. The source of truth is the Pydantic models in `backend/models/`; when the server is running, `/docs` shows the same contract interactively.

- **Base URL:** `https://drivesave.nuhylabs.com` (Vultr, [deployment guide](deploy.md)). For local development: `http://localhost:8000`.
- **Auth:** call `POST /users` once, keep the returned `token`, and send `Authorization: Bearer <token>` on every other request.
- **Times:** UTC, ISO 8601 with a timezone (`2026-10-24T20:01:00Z`). Times without a timezone are rejected.
- **Money:** USD, rounded to 4 decimal places because amounts are often a cent or less; format them for display. Every dollar figure is an estimate (`is_estimate: true`).
- **Errors:** always this shape, whatever the status code:

```json
{"error": {"code": "wrong_join_code", "message": "That join code does not match this crew"}}
```

Validation errors (422) use `code: "validation_error"` and add a `details` list with the field location of each problem.

## Endpoints

"Status" says what works today. Placeholder means the response has the final shape but uses fixed inputs until the real implementation lands.

| Method and path | Purpose | Status |
| --- | --- | --- |
| `GET /health` | Deployment check (no auth) | Done |
| `POST /users` | Create a user; returns `user_id` and `token` (no auth) | Done |
| `PUT /users/me/vehicle` | Send the driver's car data from the EPA dataset; stored as-is | Done |
| `GET /users/me/vehicle` | The car data, exactly as sent | Done |
| `GET /users/{user_id}/progress` | Baseline, weekly trend, estimated savings (self only) | Done |
| `POST /trips` | Upload a trip summary, detected events and GPS speed readings | Done, idempotent |
| `GET /trips/{trip_id}/receipt` | Financial receipt and assumptions (owner only) | Done, priced by the data teammate's Mazda5 fuel model |
| `GET /trips/{trip_id}/cost-input` | Exactly what the cost model receives for a trip (owner only) | Done |
| `POST /crews` | Create a crew; the creator joins automatically | Done |
| `POST /crews/{crew_id}/join` | Join with `{"join_code": "..."}` | Done |
| `GET /crews/{crew_id}` | Members, count, `active` (4+ members) | Done |
| `GET /leaderboard` | The members of your crew, ranked against each other | Done |

Not in the skeleton yet: `POST /games` + `WS /ws/games/{code}`, `POST /admin/demo/reset`.

## Vehicles

The app lets the driver pick their car from the EPA dataset and sends that car's data with `PUT /users/me/vehicle`. The body is a JSON object with any fields. The backend doesn't read or change them; it stores the object as sent. The current fuel model supports one car, a 2012 Mazda5, and prices every trip as that car, so the driver's car stays on file for models that support more cars.

Example body: [`fixtures/sample-vehicle.json`](../fixtures/sample-vehicle.json), built from a real row of the EPA Test Car List.

- The body must be a JSON object with 1 to 200 fields, under 20 KB.
- `GET /users/me/vehicle` returns the object exactly as sent, or `404` with `vehicle_not_set`.

## Trips

`POST /trips` takes the trip summary, the events detected on the phone, and the phone's GPS speed readings. The client never sends dollar amounts; the server prices every trip.

Example request: [`fixtures/sample-trip.json`](../fixtures/sample-trip.json).

| Field | Type | Rules |
| --- | --- | --- |
| `client_trip_id` | UUID | Generated on the phone once per trip. Re-uploading the identical trip returns the original with `200` and `duplicate: true`; a different trip under the same id returns `409` with `trip_conflict` |
| `started_at`, `ended_at` | datetime | `ended_at` must be after `started_at` |
| `distance_mi` | number | Greater than 0, at most 1000 |
| `avg_speed_mph` | number | 0 to 120 |
| `source` | string, optional | `recorded` (default), `replayed` or `synthetic`. Replayed and synthetic trips must set `is_demo: true` |
| `is_demo` | boolean, optional | Ignored for now: while the fuel model is experimental, every trip is stored as a demo trip and responses say `is_demo: true` |
| `events_complete` | boolean, optional | **Needed for a receipt.** Set `true` only when the event detector ran for the whole trip, so `events` lists every harsh moment. Default `false`: the trip is stored but not priced |
| `detector_version` | string, optional | **Needed for a receipt.** Version of the detector that ran for the trip, e.g. `"ios-0.1.0"` (1 to 64 characters). Every event's `detector_version` must match it |
| `events[]` | list | Each event must fall inside the trip window; at most 10 events per minute |
| `events[].event_id` | UUID | Generated on the phone, unique within the trip, unchanged when the trip is re-uploaded |
| `events[].type` | string | `harsh_brake`, `rapid_accel` or `sharp_turn` |
| `events[].ts` | datetime | When the event started |
| `events[].detector_version` | string | Version of the phone's event detector, for example `ios-0.1.0` |
| `events[].peak_g` | number | Peak acceleration in g, above 0 and at most 2.0: forward/backward for `harsh_brake` and `rapid_accel`, sideways for `sharp_turn` |
| `events[].speed_before_mph`, `speed_after_mph` | number | 0 to 120 |
| `events[].duration_s` | number, optional | **Needed for a receipt.** How long the event lasted, in seconds (up to 60) |
| `events[].heading_change_deg` | number, optional | How far the car turned, 0 to 360 degrees. Send it for `sharp_turn` |
| `speed_samples[]` | list | GPS speed readings, about one per second, in any order; up to 21,600. **Required when the trip has events** |
| `speed_samples[].ts` | datetime | When the reading was taken (absolute UTC time); inside the trip window |
| `speed_samples[].sample_seq` | integer | 0 or more, unique within the trip; a simple counter works |
| `speed_samples[].speed_mps` | number or null | `CLLocation.speed` in m/s, sent as-is. Negative (invalid) or above 53.6448 (120 mph) is stored as null |
| `speed_samples[].speed_accuracy_mps` | number or null | `CLLocation.speedAccuracy` in m/s, sent as-is. Negative (invalid) is stored as null |

Every number must be finite: NaN and infinity are rejected. Don't send coordinates; the backend doesn't store location.

**Speed readings:** log every location update for the whole trip, about one per second, with the first reading at `started_at` and the last at `ended_at`. The fuel model prices a trip only when the readings cover it without gaps over 3 s, `distance_mi` matches them within 10%, and each event's speeds match GPS within 2 m/s. A trip that misses one of these is still stored; its receipt returns `409` `trip_not_scored` with the reason. The full list is in [`docs/cost-model.md`](cost-model.md).

Response (`201`, or `200` for a duplicate):

```json
{"trip_id": "51f08747-…", "receipt_url": "/trips/51f08747-…/receipt", "duplicate": false}
```

## Receipt

Example response: [`fixtures/sample-receipt.json`](../fixtures/sample-receipt.json). The iOS app can bundle this file as its offline fallback.

Trips are priced by the data teammate's Mazda5 fuel model ([`docs/cost-model.md`](cost-model.md)). Its estimates are experimental: **show `label` ("Estimated fuel savings; accuracy not yet validated") with the amounts.**

- `events[].cost_usd`: what each event cost. Braking and acceleration have a cost; sharp turns are coaching only and cost $0.
- `high_speed_cost_usd`: the cost of driving above 65 mph, which isn't tied to an event.
- `avoidable_cost_usd`: the trip's total: the event costs plus `high_speed_cost_usd`.
- `cost_model`: which model produced the amounts, `notion-mazda5-2012-auto-v1`.
- `assumptions[]`: every numeric constant with its `source_url` and `as_of` date, including the fuel price (`gas_price`). `is_estimate: true` marks team assumptions rather than published figures; show those as "estimate" in the UI.
- `notes[]`: the assumptions that aren't numbers, such as `road_conditions: level, no wind, warm engine`.
- A trip the model couldn't price returns `409` with `trip_not_scored`; `message` names the reason, for example `event_recording_incomplete`.

## Crews and leaderboard

**Drivers compete against each other inside their crew.** Crews don't compete with other crews.

- A driver belongs to one crew at a time. Creating or joining another crew moves them out of their current one.
- The competition counts once the crew has 4 or more members (`active: true`).
- `join_code` is 6 characters (no 0/O or 1/I), case-insensitive, and only returned to members. Put `crew_id` and `join_code` in the QR code.
- `GET /leaderboard` (no parameters) ranks the members of your crew. If you aren't in a crew it returns `404` with `not_in_crew`.
- The baseline is a driver's first 3 priced trips of at least a mile. `improvement_pct` = (baseline − this week's waste per mile) ÷ baseline × 100, counting only this week's later trips (weeks start Monday 00:00 UTC). Ties share a rank.
- Each standing has a `state`: `ready`, `collecting_baseline`, `zero_baseline` (the baseline had no harsh events) or `no_weekly_trips`. Drivers who aren't `ready` come last, with `rank` and `improvement_pct` set to null and `est_savings_usd` set to 0.
- `trips_counted` counts this week's trips after the baseline. `est_savings_usd` is signed: negative means the driver wasted more than their baseline.
- `is_demo: true` on the leaderboard means a demo crew. Always label it in the UI. While the fuel model is experimental, every crew is a demo crew.

## Storage

- Everything is stored in Tiger Data (Postgres + TimescaleDB), so restarts and redeploys keep users, crews and trips.
- The database (schema version 4) calls crews leagues. The API keeps the crew names and routes, so nothing changes for the app.
- Each trip is priced once, when it's uploaded, and the result is saved with it. `GET /trips/{trip_id}/receipt` returns `409` with `trip_not_scored` if the fuel model couldn't price the trip.
- Every crew and trip is stored as demo data while the fuel model is experimental; the schema only accepts its results on demo trips.
