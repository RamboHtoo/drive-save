# Set up the Drive Save database

This is the shared v1 schema for Person 2 and Person 3. It prepares storage;
it does not implement a fuel model, detect events, or calculate baseline slots.

## Apply to the empty Tiger Cloud service

1. Open the service's SQL Editor.
2. Paste the entire contents of `analytics/schema.sql` and run it.
3. Expect the final result to show schema version `1` and an application timestamp.
4. Run `analytics/verify.sql`. Expect three hypertables and one continuous aggregate
   with `materialized_only = false` and a scheduled refresh job.

The script uses a transaction and preserves data on rerun. If it fails, execute
`ROLLBACK;` before retrying in the same editor connection. Share the error text,
not the database password. Rerun safety applies to this exact v1 definition;
`IF NOT EXISTS` does not migrate tables independently created with different columns.

No demo data is inserted. No passwords or database roles are created. Person 2
should provision a backend application role with only the access its routes need;
keep schema administration credentials separate. Database credentials belong in
the backend environment, never the iPhone app or Git.

## Tables

- `users`, `crews`, `crew_members`: backend-owned identities and current membership.
  A user belongs to at most one crew in v1.
- `trips`: source of truth; a client trip UUID is unique per user. Replay and
  synthetic trips must be marked as demo. Unscored is distinct from zero cost.
- `trip_events`: detected possible harsh maneuvers, including detector version.
  Event-level cost is optional and must come from the server model.
- `speed_samples`: GPS speed observations with timestamps, sequence numbers, and
  optional accuracy. Convert invalid GPS speed/accuracy to NULL before insertion.
- `scoring_configs`: immutable model, vehicle, price, and assumption snapshots.
  Each assumption object should contain key, value, unit, source_url, and as_of;
  source_url can be null for explicitly labeled user-entered assumptions.
- `trip_metrics`: server-produced projection of a completed financial estimate.
- `daily_user_metrics`: daily continuous aggregate over metrics, retaining separate
  user, crew, configuration, baseline, and demo groups.
- `savings_ledger`: signed estimated improvement; never a record of a bank transfer.
- `game_results`: separate parked-game results; do not count them as fuel savings.

## Backend handoff requirements

Use UUIDs, timezone-aware UTC dates, and explicit units. Core Motion peaks are in
g, display speeds in mph, and GPS observations in m/s. Money is USD; do not round
until rendering. The initial three event types match Backend Plan. Coordinates
and full accelerometer streams are intentionally absent.

`POST /trips` should accept stable event UUIDs, detector_version, and optionally a
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
Separate demo and real queries explicitly. Crew membership history is represented
by the crew_id copied into each accepted trip; joining another crew does not
transfer old trip metrics to that crew.

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
2. Run `analytics/demo_seed.sql`. This adds two clearly named demo crews with four
   drivers each and 32 synthetic trips, then returns a demo leaderboard.
3. Expected results: Demo East Halls is first with 20% improvement and $0.80 estimated
   savings; Demo West Halls is second with 10% and $0.40. Both have four eligible
   drivers and is_demo = true. These are invented fixture values, not model results.

The seed can be rerun without duplicating rows. It does not move old fixture dates
to the current week. If reused next week, query the original fixture's week. The
speed traces are sparse examples for testing storage only; they cannot validate
a fuel simulator.

`tests/analytics_queries.sql` exercises arithmetic and edge cases with all test
changes rolled back. Use a disposable test service and run it on the creation day;
historical Timescale materializations may need refresh before testing changes.

## Backend query interface

Bind parameters through asyncpg, never by interpolating user input. For example:

```python
rows = await connection.fetch(
    "SELECT * FROM public.drive_save_crews($1::timestamptz, $2::boolean)",
    week_start, False,
)
```

- `drive_save_baseline(user_id, scoring_config_id, is_demo)` returns count, rate,
  and collecting_baseline / zero_baseline / ready status.
- `drive_save_members(week_start, is_demo, crew_id DEFAULT NULL)` returns member
  standings, including null ranks for unready members. NULL crew means all crews.
- `drive_save_crews(week_start, is_demo)` returns crew standings and both total
  membership and eligible-member counts. Four registered members and at least one
  eligible member are required to rank. Percentage improvement is averaged equally
  across eligible members; ranks are dense, with shared ranks for ties.
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
from the token, and crew queries must be authorized before running. SQL functions
are invoker-security functions; the database is not a public API.

Rankings use each user's latest accepted non-null scoring configuration in the
selected demo/real cohort. A new configuration starts baseline collection again;
the previous configuration's results do not contribute to the active ranking.
Trip crew snapshots must match current membership for competition; old trips do
not follow a user into a different crew. Rankings include all scored later-trip
distance; the one-mile threshold applies to baseline collection only.

For refresh-job health, run the read-only job query in `analytics/verify.sql`;
being scheduled is not evidence that every execution has succeeded. Financial
estimates and baseline comparisons still require model validation; the database
does not make them measured savings.
