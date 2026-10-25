# League API integration contract (v2)

The SQL schema and analytics are implemented. Person 2 implements these HTTP
routes; Person 1 consumes them in SwiftUI. This repository has no backend or iOS
code yet. The local schema is v4; apply migration 004 to a v3 cloud database before
using event durations and detector coverage. Callers using crew table names or
drive_save_crews / drive_save_members must be updated.

## Membership and recording

- `POST /leagues`: authenticated, body `{ "name": "East Halls Driver Challenge" }`;
  create a league and membership for its creator. Return league_id and join_code.
- `POST /leagues/{league_id}/join`: authenticated, body `{ "join_code": "..." }`;
  verify the code then insert/update that user's single current league membership
  transactionally. Return league_id. A wrong code returns the backend's 403 error.
- `GET /leagues/{league_id}`: current members only; return league_id, name,
  member_count, and player IDs/nicknames. Do not expose token hashes or other
  players' trip receipts. A four-player demo requirement does not block rankings.
- `POST /trips`: existing recording fields stay the same. Resolve league_id from
  the authenticated user's membership and copy it into trips and trip_metrics.
  Trips recorded without a league still support receipts and personal history.

One current league per driver is enforced by league_members.user_id. Preserve
historical trip league snapshots when a user joins another league. Their personal
baseline follows their scoring configuration, but their previous league's trips
do not contribute to the new league's standings. The app should explain that
the new league needs later trips before it can show a rank.

## Individual leaderboard

`GET /leaderboard?league_id={uuid}&period=week`

Authorize that the requester is a member of the requested league, compute the
current Monday-00:00-UTC week boundary, and query with bound parameters:

```python
rows = await connection.fetch(
    "SELECT * FROM public.drive_save_leaderboard($1::uuid, $2::timestamptz, $3::boolean)",
    league_id, week_start, is_demo,
)
```

The backend sets is_demo from its authenticated demo mode / league configuration;
do not allow arbitrary client flags to mix real and synthetic rows. Public/demo
display routes must still omit private receipts and credential information.

Return `{ "league_id": "...", "period": "week", "standings": [...] }`. Each row
includes rank (nullable), user_id, nickname, improvement_pct (nullable),
est_savings_usd (nullable), distance_mi, trip_count, state, and is_demo. Additional
SQL result fields can support an explanation screen without changing ranking.
Round values only for display; preserve the signs of negative improvement/savings.

Rank highest percentage improvement first. Baseline is the distance-weighted
estimated waste per mile across the first three eligible trips. Later trips only
contribute to weekly competition. Equal percentages share a rank; total dollars
are informational and do not break ties. The supported states are ready,
collecting_baseline, zero_baseline, and no_weekly_trips.

The SQL function accepts a timestamp within the desired UTC week and normalizes
it. Unknown/null league IDs return no rows, but authorization and UUID validation
remain API responsibilities. Keep existing owner-only receipt and progress routes.

## UI and test acceptance

Show a league's individual players and their improvement/savings. Replace collective
crew totals, shared crew goals, and crew-versus-crew rankings with personal progress.
Include an explanation of the baseline and label modeled savings as estimates.

Use the new demo league `e0000000-0000-4000-8000-000000000001`. Alex, Blair, Casey,
and Drew should rank with 20%, 10%, 0%, and -10% improvement. Test a smaller league,
ties, baseline collection, a league switch, and owner-only receipt access. Four
participants should be able to join for the hackathon demonstration. Parked-phone
game results remain separate from fuel-efficiency rankings.

## Mazda5 recording payload (v4)

For the new model, speed_samples are required throughout the trip. Add trip-level
`events_complete` and `detector_version`; upload an explicit events list, including
`duration_s` and start-time `ts` for each event. Only completed detector sessions
may set events_complete=true. Missing samples/events produce an insufficient-data
receipt and no rank. See [the complete scoring contract](fuel-model.md).

The server chooses the fixed Mazda5 profile and immutable configuration. These
estimates remain demo-only even for recorded phone trips. Receipt `model_result`
contains per-event results and a separate high-speed contribution. The existing
`avoidable_fuel_usd` is their total; do not add it to the separate trip-fuel budget.
Display “Estimated fuel savings; accuracy not yet validated.”
