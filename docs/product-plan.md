# Drive & Save: individual competition

## Product direction

Drive & Save helps individual drivers challenge each other to develop better
driving habits and understand the estimated financial effects of their choices.
Phone motion and location observations support trip recording; the server produces
an explainable post-trip receipt and updates each driver's league standings.

Players join community leagues, such as East Halls Driver Challenge or Penn State
Commuter League. A league organizes competing individuals; it does not receive a
combined driving score. Replace crew-versus-crew competition, shared crew savings,
and crew-wide penalties with individual performance and personal savings goals.

## Players and ranking

- Keep the agreed personal baseline: the first three eligible accepted trips under
  the same scoring configuration, each at least one mile. The distance-weighted
  baseline is total estimated avoidable fuel cost divided by total miles.
- Rank individuals within their league by weekly percentage improvement over
  their own baseline, highest first. Use later trips only. Preserve negative
  improvement, and leave incomplete/zero baselines or empty weeks unranked.
- Show estimated savings in USD alongside the rank, calculated as baseline USD
  per mile times weekly miles minus this week's estimated avoidable fuel cost.
  Keep total savings informational so driving farther does not determine rank.
- Display weekly waste per mile, eligible distance, and trip count so participants
  can understand their results. Give equal improvement percentages shared ranks.
- Keep personal progress history, trip receipts, transparent assumptions, and a
  simulated personal savings goal. Estimated savings are not verified bank savings.
- Keep real and synthetic data separated. New scoring configurations start a new
  baseline. UTC calendar weeks start Monday, as in the existing analytics contract.

## Leagues and the four-player demonstration

For the MVP, each driver belongs to one league at a time. Players join by an
invitation code. A league can show individual standings before four people join;
there is no four-member eligibility gate on an individual driver's ranking.

The app must still support at least four participants for the Mystery Stack demo.
Invite four real testers into the same league. Retain the separate parked-phone
motion challenge for simultaneous rivalry, subject to organizer interpretation;
parked-game scores do not count as fuel savings. League size alone does not prove
that all challenge requirements are satisfied.

## Implementation and integration

The data and analytics implementation now uses leagues. Migration 002 has been
applied to the development cloud service, preserving the original trip records.
The local schema, tests, and development cloud service now use v4, adding event
duration and detector coverage. Migration 004 has been applied and verified,
preserving all 48 existing trips, 48 metric rows, and 96 events. Trip and event
fingerprints are unchanged; the one-minute refresh policy remains scheduled.

- Database (implemented): renamed crews to leagues, crew_members to league_members,
  and crew_id snapshots to league_id on trips and trip_metrics. Original records,
  baseline slots, financial outputs, aggregate history, and refresh policy remain.
- Analytics (implemented): a league-scoped individual leaderboard replaces the
  retired crew functions. Baseline, receipt, progress, and quality queries remain.
- API: replace crew creation/join/info routes with league routes. Use
  GET /leaderboard?league_id=...&period=week for individual standings. Each row
  contains rank, user_id, nickname, improvement_pct, est_savings_usd, distance_mi,
  trip_count, state, and is_demo. Person 2 authorizes league access and sets the
  real/demo mode on the server.
- iOS: show player profiles, league membership, individual standings, and personal
  savings. Replace crew totals and crew-versus-crew screens. Recording and receipts
  keep their current responsibilities.
- Demo (implemented): four individual players have synthetic improvements of 20%,
  10%, 0%, and -10%. Their cloud standings have been verified. Tests cover ties,
  negative improvement, baseline collection, league isolation, and reruns.
- Fuel model: the offline Notion-based Mazda5 model replaces the former simulator.
  The first supported car is the 2012 Mazda5 automatic (FuelEconomy.gov 31284).
  Complete phone GPS and event recordings feed fuel-only braking, acceleration,
  and high-speed estimates. Wear and annual projections are excluded.
  Rankings remain based on estimated waste-per-mile improvement, not a new
  behavior score. Dollar estimates remain experimental and demo-only.
  Published lab comparisons do not validate individual-event savings.


Person 1 owns the iOS changes; Person 2 owns league APIs, membership, authentication,
and integration; Person 3 owns the data migration, league analytics, financial
estimator, and financial explanation. Person 2 and Person 1 should integrate using
docs/league-api.md; their backend and iOS implementations are not present in this
repository.
