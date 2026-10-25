# Set up the Drive Save database

Drive Save uses individual competition within leagues. See the
[product plan](product-plan.md) and [league API contract](league-api.md).

## Upgrade the existing cloud service

The local schema and development Tiger Cloud service are both v4. Migration 004
(`analytics/migrations/004_mazda_math_model.sql`) was applied to `db-59555` on
2026-10-24. It adds event
duration, detector completion/version, and experimental-model demo enforcement.
Verification found 48 trips, 48 metric rows, and 96 events before and after.
Ordered trip and event fingerprints, excluding the newly added fields, remained
`7b7e331331b69ba5d5ce572cc6963d13` and `f38347ff2691666ed08cc7da67d9a416`.
All existing receipts expose the new coverage keys. The one-minute continuous
aggregate refresh policy remains scheduled. No model-generated trips were inserted.
For another v3 service, apply migration 004 before using the Mazda5 scorer.

Migration 003 was previously applied to development Tiger Cloud
service `db-59555` on 2026-10-24 at approximately 18:08 America/New_York, after 002.
It preserves old trip values and adds no new table. Verification found 48 trips and
48 metric rows before and after; the ordered trip-history MD5, excluding the new
nullable field, remained `1f4f608801d1cbfe6ac422829c61fd62`. All existing receipts
include the new key, one refresh job remains scheduled, and real-time aggregation
remains enabled. No model-generated trips were inserted into the cloud by this run.

On another v2 database, apply `analytics/migrations/003_fuel_model_receipts.sql`
followed by migration 004.
New empty databases use the current v4 schema. See `docs/fuel-model.md` for the
Python scoring adapter.

Run the entire `analytics/migrations/002_individual_leagues.sql` in SQL Editor.
It renames the existing tables and snapshot columns, installs the new analytics
functions, and retires the old crew leaderboard functions in one transaction.
It preserves original trips and the continuous aggregate's stored history and
refresh policy. It can be safely rerun. No demo users/trips are deleted.

Migration 002 has been applied to the development cloud service. Counts immediately
after migration were unchanged: 32 trips, 64 events, 128 speed samples, and 32 metrics.
For another v1 service, run the migration; for a new empty service, follow the
fresh-install instructions below. Do not apply the fresh schema over a v1 service.

This is the shared v4 schema for Person 2 and Person 3. SQL prepares storage;
the Python model and adapter implement experimental estimates and baseline assignment.
The phone application still owns motion-event detection.

## Apply to the empty Tiger Cloud service

1. Open the service's SQL Editor.
2. Paste the entire contents of `analytics/schema.sql` and run it.
3. Expect the final result to show schema version `4` and an application timestamp.
4. Run `analytics/verify.sql`. Expect three hypertables and one continuous aggregate
   with `materialized_only = false` and a scheduled refresh job.

The script uses a transaction and preserves data on rerun. If it fails, execute
`ROLLBACK;` before retrying in the same editor connection. Share the error text,
not the database password. Rerun safety applies to this exact v4 definition;
`IF NOT EXISTS` does not migrate tables independently created with different columns.
Existing v2 installations must run 003 then 004; v3 installations run 004.

No demo data is inserted. No passwords or database roles are created. Person 2
should provision a backend application role with only the access its routes need;
keep schema administration credentials separate. Database credentials belong in
the backend environment, never the iPhone app or Git.

## Tables

- `users`, `leagues`, `league_members`: backend-owned identities and current membership.
  A user belongs to at most one league in this MVP.
- `trips`: source of truth; a client trip UUID is unique per user. Replay and
  synthetic trips must be marked as demo. Unscored is distinct from zero cost.
  `model_result` contains scenario breakdowns, diagnostics and validation status.
  Experimental math results and historical reference simulations must be demo.
  `events_complete` defaults to false; `detector_version` identifies the trip detector.
- `trip_events`: detected possible harsh maneuvers, including detector version.
  `duration_s` is required by the new model but nullable for legacy history.
  Event-level cost is optional and must come from the server model.
- `speed_samples`: GPS speed observations with timestamps, sequence numbers, and
  optional accuracy. Convert invalid GPS speed/accuracy to NULL before insertion.
- `scoring_configs`: immutable model, vehicle, price, and assumption snapshots.
  Each assumption object should contain key, value, unit, source_url, and as_of;
  source_url can be null for explicitly labeled user-entered assumptions.
- `trip_metrics`: server-produced projection of a completed financial estimate.
- `daily_user_metrics`: daily continuous aggregate over metrics, retaining separate
  user, league, configuration, baseline, and demo groups.
- `savings_ledger`: signed estimated improvement; never a record of a bank transfer.
- `game_results`: separate parked-game results; do not count them as fuel savings.

## Backend handoff requirements

Use UUIDs, timezone-aware UTC dates, and explicit units. Core Motion peaks are in
g, display speeds in mph, and GPS observations in m/s. Money is USD; do not round
until rendering. The initial three event types match Backend Plan. Coordinates
and full accelerometer streams are intentionally absent.

`POST /trips` should accept stable event UUIDs, detector_version, plus event start time and duration. The Mazda5 model requires a complete
speed_samples array with ts, sample_seq, speed_mps, speed_accuracy_mps. The server
infers user_id from the token. It validates event/sample timestamps against the
trip interval, finite numeric inputs, unique event IDs and sample sequences within
the upload, and the configured payload limits before insertion. API validation
must also reject nonfinite numeric financial values, including PostgreSQL NaN.

For each accepted trip, lock the user's row while checking duplicates and assigning
baseline positions. Identical retries return the existing trip; a changed payload
under the same client_trip_id is a conflict. Compare canonical payloads with saved
trip/events/samples; do not blindly upsert them. Persist all rows atomically.

Assign slots 1–3 to the first eligible accepted trips, separately by user,
scoring_config_id and is_demo. Eligibility requires scored status and distance >=
1 mile. The unique constraint prevents a fourth baseline slot; do not renumber
slots for late uploads. A configuration change starts a new baseline. Freeze the
baseline after slot 3; calculate it as SUM(avoidable_usd)/SUM(distance_mi).

On successful scoring, insert trip_metrics using INSERT ... SELECT from the
stored trip: ts = started_at, identical identity/configuration/distance/cost/demo
fields, and is_baseline = (baseline_slot IS NOT NULL). Do this in the scoring
transaction. Do not insert metrics for unscored trips, or use client dollar values.
This prevents duplicated trip totals when events are joined for receipts.

UTC calendar weeks begin Monday; a whole trip belongs to its start day. Later-trip
improvement is (baseline - weekly cost per mile)/baseline. Keep negative results;
return unranked for incomplete or zero baselines and weeks without eligible trips.
Separate demo and real queries explicitly. League membership history is represented
by the league_id copied into each accepted trip; joining another league does not
transfer old trip metrics to that league.

## Continuous aggregate behavior

The view starts empty with real-time aggregation explicitly enabled. New current
data is included without waiting for scheduled materialization. The one-minute
policy refreshes completed daily buckets inside its 30-day window, excluding the
most recent hour. Late changes to already materialized days appear after refresh;
do not promise immediate standings for historical uploads. For older fixtures,
manually refresh complete UTC day ranges before presenting their trends.

## Install analytics and check the demo

1. Run the entire `analytics/queries.sql` in SQL Editor. This installs SQL functions
   that the backend can call using asyncpg; no Python analytics dependency is needed.
2. Run `analytics/demo_seed.sql`. This adds one labeled demo league with four
   drivers and 16 synthetic trips, then returns individual standings.
3. Expected results: Demo Alex 20% / $0.20; Demo Blair 10% / $0.10; Demo Casey
   0% / $0.00; Demo Drew -10% / -$0.10. They rank 1 through 4. All figures are
   invented fixture values and all rows have is_demo = true.

The seed can be rerun without duplicating rows. It does not move old fixture dates
to the current week. The seed's final query uses the original fixture's week, even
on a later rerun. The speed traces are sparse examples for testing storage only; they cannot validate
a fuel simulator.

`tests/analytics_queries.sql` exercises arithmetic and edge cases with all test
changes rolled back. Use a disposable test service and run it on the creation day;
historical Timescale materializations may need refresh before testing changes.

## Backend query interface

Bind parameters through asyncpg, never by interpolating user input. For example:

```python
rows = await connection.fetch(
    "SELECT * FROM public.drive_save_leaderboard($1::uuid, $2::timestamptz, $3::boolean)",
    league_id, week_start, False,
)
```

- `drive_save_baseline(user_id, scoring_config_id, is_demo)` returns count, rate,
  and collecting_baseline / zero_baseline / ready status.
- `drive_save_leaderboard(league_id, week_start, is_demo)` returns individual
  standings for exactly that league. A null or unknown league returns no rows,
  never global standings. Unready drivers have null ranks. There is no minimum
  league size for ranking a driver. Ranks are dense, with shared ranks for ties.
- `drive_save_progress(user_id, scoring_config_id, is_demo, start_day, end_day)`
  returns daily history including baseline trips. Pass UTC-midnight boundaries,
  end exclusive. Days without data are omitted, not represented as zero spending.
- `drive_save_receipt(trip_id, user_id)` returns a JSON receipt or NULL. The backend
  maps NULL to its normal not-found response. It omits annual forecasts until a
  projection method exists and does not assign invented costs to motion events.
- `drive_save_timeline(trip_id, user_id)` groups events into ten-second intervals.
- `drive_save_speed_trace(trip_id, user_id)` returns the ordered GPS observations.
- `drive_save_quality(user_id, is_demo)` returns sample counts, scoring state, and
  whether each trip's analytics projection matches its source row.

The API still owns authorization. User IDs passed to private queries must come
from the token, and league queries must be authorized before running. SQL functions
are invoker-security functions; the database is not a public API.

Rankings use each user's latest accepted non-null scoring configuration in the
selected demo/real cohort. A new configuration starts baseline collection again;
the previous configuration's results do not contribute to the active ranking.
Trip league snapshots must match current membership for competition; old trips do
not follow a user into a different league. Rankings include all scored later-trip
distance; the one-mile threshold applies to baseline collection only.

The old drive_save_members and drive_save_crews functions are retired. Person 2
must update their callers to drive_save_leaderboard and the league routes in the
API contract before deploying the backend. No backend or iOS implementation is
present in this repository yet; those changes remain with their respective owners.

For refresh-job health, run the read-only job query in `analytics/verify.sql`;
being scheduled is not evidence that every execution has succeeded. Financial
estimates and baseline comparisons still require model validation; the database
does not make them measured savings.
