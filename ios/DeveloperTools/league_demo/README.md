> Release integration (2026-10-25): the implementation now lives in `backend/services/league_demo.py` and `backend/routes/league_costs.py`; `backend/main.py` registers routes once. Apply `backend/db/004_league_demo.sql` only through an approved deployment. The old Python adapter is a compatibility import. The instructions/results below describe the original local proposal; the current release report in `docs/release-hackpsu-final.md` supersedes its integration and test status. Production remains untouched.

# Five fictional members in Htoo's existing league

**Prepared and tested locally. Nothing has been deployed or seeded in Tiger Cloud.**
The production league ID has not been guessed or inferred from a nickname. The scripts resolve it from the existing authenticated account at execution. No production token was read for this task.

## Expected showcase

| Rank | Member | Weekly estimated avoidable cost | Provenance |
| --- | --- | --- | --- |
| 1 | Alex · Synthetic demo | $1.85 | Supplied illustrative example |
| 2 | Jordan · Synthetic demo | $2.40 | Supplied illustrative example |
| 3 | Sam · Synthetic demo | $3.12 | Supplied illustrative example |
| 4 | Taylor · Synthetic demo | $4.30 | Supplied illustrative example |
| 5 | Casey · Synthetic demo | $5.75 | Supplied illustrative example |
| — | Htoo | Unavailable if no eligible scored trips | Actual recorded/scored trips only |

If Htoo has actual eligible scored recorded trips in the current UTC week, their stored avoidable costs are summed and ranked among the examples by cost. Htoo is never assigned an example. Ties share a dense rank. Unscored trips and no-data drivers are unranked, rather than receiving zero. Improvement does not influence rank. No 3-trip baseline is required for the new cost metric.

All six are members of the **same existing league**. If that league already contains other members, they are preserved and the live board will contain more than six; the authenticated plan reports the before/after member counts. Showcase ordering is explicitly a demonstration, never genuine competition. Demo identities cannot satisfy the four-real-member qualification, earn financial progress or contribute to genuine rankings.

## Why backend changes are necessary

Inspected backend `5094a01bb2844cfd9819ad8b8ec55f13dc26acf5` and analytics `354588549c31d9fdd03a6665ec2c703912384ad6` after fetching both branches:

- `analytics/schema.sql` v4: users, leagues, league_members, trips, metrics, immutable scoring configurations and constraints.
- `analytics/queries.sql`: current ranking is **improvement descending**, not weekly avoidable cost.
- Existing `/leaderboard` omits weekly avoidable cost and per-player synthetic provenance. The signed `est_savings_usd` field is a different measure and must not be relabeled as cost.
- Existing `seed_demo_league.py` creates a new league/accounts on each run and changes synthetic fixture speeds. It is intentionally not used.
- Existing `POST /users` has no idempotency key or caller-supplied ID, no persistent demo-identity registry, and no account cleanup endpoint. Using it repeatedly cannot meet atomic retry/cleanup guarantees. Existing auth and membership logic are reused; a bounded transaction is necessary for idempotent demo provisioning.

The reviewed proposal is `backend/db/004_league_demo.sql` plus `backend/services/league_demo.py`. They are kept under `/ios/DeveloperTools` as a handoff; the backend/analytics working trees are unmodified. An explicit backend deployment is required before production seeding or remote showcase display works.

## Data isolation and preservation

`drivesave_demo` owns batches, five registered fictional identities and `synthetic_trips`. These records carry `source=synthetic`, `is_demo=true`, `estimate_kind=supplied_demo_example` and `status=demo_ready` or `unscored`. **demo_ready means an explicitly supplied display example, not a fuel-model-scored physical trip.** No GPS, motion, fuel gallons, baseline or financial savings is invented.

The example amounts never enter `public.trips`, `trip_metrics`, `daily_user_metrics`, scoring configs, baselines, game results or savings ledger. Htoo's real history, token hash, vehicle and membership are not written. The five public account IDs are UUIDv5 values scoped to the authenticated owner, verified league and seed version; they are separate from Htoo and each other. Their public nicknames include “Synthetic demo”. Unrecoverable random credential hashes prevent accidental ordinary logins; no demo tokens are exported.

The transaction locks its batch, rechecks membership before writes and rejects UUID collisions, modified demo names or moved demo memberships. Repeated/concurrent runs do not create duplicates or overwrite unrelated users. A new UTC week adds one example per demo identity/week, not a new account.

Cleanup checks owner, exact batch tag, all five reserved IDs/names/memberships and unexpected public trips. Any unexpected public trip stops cleanup atomically for review. It deletes only registered demo children, those five memberships and those five users. It does not delete or recreate the league, Htoo, any Htoo trip, or unrelated demo accounts.

## Read-only identification now — existing deployed API

Run locally, entering the **existing** Htoo bearer token at the hidden prompt (or supply it via a protected `DRIVESAVE_TOKEN` environment). Never paste tokens into chat or commit them:

```sh
python3 DeveloperTools/league_demo/inspect_existing_league.py \
  --base-url https://drivesave.nuhylabs.com
```

Only GET requests are made: self-scoped `/leaderboard`, private `/crews/{resolved_id}`, and self-only `/users/{candidate_id}/progress`. Nicknames are not unique: progress authorization disambiguates the actual Htoo identity from authenticated membership results. It prints the verified user and league IDs, never a token. If validation fails it stops and creates nothing.

Alternatively, after installing the reviewed iOS build through the normal development workflow: Profile → Developer Mode, Leagues → Demo showcase → Verify and export existing league. The app uses existing Keychain authentication, checks owner before/after reads, and disables account recovery for this verification. No token or join code is exported, and no account is registered/reset. The read-only export works with the old API even if the showcase extension is not deployed.

## Deployment review — explicit approval required

1. Review the isolated test evidence below and obtain approval to integrate/deploy the backend change. Do not run the schema against Tiger Cloud or deploy simply because these files exist.
2. Integrate the proposed handlers using the backend's existing `auth.get_current_user` and `db.pool`. `install(app)` is the tested adapter after existing route registration; it places overrides ahead of legacy included routers. For a permanent integration, replace the existing GET crew/legacy leaderboard handlers with the guarded versions and register the new routes directly, keeping one OpenAPI entry per route.
3. Apply `schema.sql` using the reviewed application database role. If a separate migration owner is used, explicitly grant only the required `USAGE`, `SELECT`, `INSERT`, `DELETE` permissions on this private schema/tables to the application role. Public access is revoked. No existing core schema constraint is removed.
4. Keep `DRIVESAVE_ENABLE_LEAGUE_DEMO_WRITE` unset/`0` by default. Only enable it explicitly for the approved seed/cleanup window, and set `DRIVESAVE_DEMO_PRESENTER_ID` to the **authenticated, reviewed existing Htoo UUID**. Both are required; a nickname alone never authorizes writes. Read routes remain authenticated.
5. Deploy the iOS changes together with backend support. Until then, unsupported remote showcase requests display unavailable and never substitute offline fixtures. Legacy improvement ranks are not presented as cost ranks.

Routes added: GET `/developer/league-demo/plan`, POST `/developer/league-demo/seed/{confirmed_league}`, DELETE `/developer/league-demo/{batch}`, GET `/leaderboard/costs`, GET `/leaderboard/demo`.

The two existing read handlers also need demo qualification guards: GET `/crews/{id}` and legacy GET `/leaderboard`. Original league flags and members are preserved. Legacy response fields remain compatible, while demo identities cannot activate real competition. New cost ranking uses `source=recorded,status=scored` for real drivers, independently of experimental `DEMO_ONLY` result flags; illustrative rows are used only by the explicit showcase endpoint.

## Seed plan and production execution

First, a **dry run** with the existing Htoo token. This verifies the current association server-side and prints the exact five IDs, batch and current league:

```sh
python3 DeveloperTools/league_demo/seed_existing_league.py \
  --base-url https://drivesave.nuhylabs.com
```

After reviewing that live plan and receiving explicit production-write approval, an operator can run (replace the placeholder with the verified plan value):

```sh
python3 DeveloperTools/league_demo/seed_existing_league.py \
  --base-url https://drivesave.nuhylabs.com \
  --allow-production --apply --confirm-league VERIFIED_LEAGUE_UUID
```

There is no `create league` operation. The endpoint resolves current membership from the authenticated account again inside the transaction; a changed association aborts the request. The client rejects remote HTTP, URL credentials and redirects, requires exact league confirmation, and defaults to dry-run. The server write gate is a separate requirement.

Cleanup defaults to dry-run as well; after approval use the **same verified league and batch**, never a nickname-prefix deletion:

```sh
python3 DeveloperTools/league_demo/cleanup_existing_league.py \
  --base-url https://drivesave.nuhylabs.com \
  --allow-production --apply --confirm-league VERIFIED_LEAGUE_UUID \
  --batch VERIFIED_BATCH_UUID
```

Disable the server write gate and clear the presenter allowlist after the approved operation. If Htoo moves to another league or any demo identity was changed, stop and review the original owned batch instead of weakening the confirmation guards.

## iOS display

The existing black/lime league screen retains the real league name, invite control and membership. Developer Mode adds an explicit **Demo showcase** for that league. Every fictional row carries its synthetic label and supplied-example provenance. Htoo uses only real scored recorded-trip totals or Not ranked. No read/view action seeds data.

Normal rankings request `/leaderboard/costs`; an old server may return the legacy payload, but the UI leaves those ranks unranked and identifies cost ranking as unavailable. Improvement may be shown separately; it never supplies cost rank. Offline fixtures are labeled and only reachable in offline mode, never as a fallback after remote failure. No sensor recording service, GPS/motion collection or financial calculation was changed by this league task.

## Isolated verification

A dedicated localhost TimescaleDB/Postgres 17 container was used, with the complete fetched analytics schema/queries and backend schema additions. Image digest: `sha256:b56a3f51991df1f79d0c1a0841cad5c5fa8058fdd6a3ee6886394a6d4c174538`. No production URL/credentials are accepted by the integration test; it hard-codes `127.0.0.1:55440/postgres`. It creates a clearly isolated Htoo fixture account and pre-existing fixture league, never the real account.

Run against a read-only backend snapshot, the dedicated test database with `backend/db/004_league_demo.sql` applied, and temporary Python dependencies matching the backend (FastAPI/asyncpg/Pydantic/NumPy; httpx for ASGI tests):

```sh
python3 DeveloperTools/league_demo/test_isolated.py /path/to/backend-snapshot
python3 DeveloperTools/league_demo/test_cli.py
bash Tests/run_recording_regressions.sh
```

Results and final simulator verification are recorded below once complete. The test-generated `league-showcase.json` is an offline snapshot of the isolated response, with no production IDs or token. It verifies all six rows, fixed example amounts and Htoo's unranked state; a separate controlled recorded-mode model fixture verifies that actual scored results, when available, are used without a fabricated target price.


Final results:

- **33 real isolated TimescaleDB/API checks passed**: authenticated league discovery; no new league; separate IDs; concurrent/idempotent seed; all six rows and requested costs; Htoo unranked when unscored; actual model receipt used when available; normal/legacy competition isolation; unchanged token hash/vehicle/membership/progress; forbidden and unexpected-data cleanup guards; idempotent bounded cleanup. Log: `/tmp/drivesave-league-demo-verified-isolated-tests.log`.
- **8 CLI safety tests passed**, including read-only duplicate-nickname disambiguation, dry-run, HTTPS, no token output/redirects, exact league/batch confirmation and production-write gate. Log: `/tmp/drivesave-league-demo-cli.log`.
- **328 portable Swift regression checks passed**, including 53 backend/auth checks, Test Calculation, owner/vehicle protection, local history, recording and telemetry. Log: `/tmp/drivesave-league-demo-verified-swift.log`; suite logs: `/tmp/drivesave-recording-tests.SZlEmU`.
- **Native build + 2/2 focused offline UI tests passed**: existing league/invite navigation and six-person showcase with ranks 1–5, synthetic provenance and Htoo Not ranked. Log: `/tmp/drivesave-league-demo-final-ui.log`; result bundle: `/tmp/DriveSaveLeagueShowcase/Logs/Test/Test-DriveAndSave-2026.10.25_08-41-29--0400.xcresult`.
- `git diff --check` passes. All changes are under `/ios`; pre-existing recording work in the workspace was preserved. No production identity, trip, league or installed iPhone app was changed. Live Htoo association verification and production seeding remain pending a securely authenticated dry run and explicit deployment/write approval.
