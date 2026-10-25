# HackPSU final release report — 2026-10-25

Review branch: `release/hackpsu-final`, targeting `main`. No deployment, production seed, production trip mutation, or main merge was performed. The original local `ios` checkout was clean and remains unchanged; integration used a separate worktree.

## Exact integration and ancestry

| Input | Exact commit |
| --- | --- |
| Base `origin/main` | `90395d381f8f15af2fcb5cd5514eb077d5a5185c` |
| `origin/backend` | `5094a01bb2844cfd9819ad8b8ec55f13dc26acf5` |
| `origin/ios` | `77f8b2dcc9788517e484a47ee1928efe81016875` |
| `origin/analytics` | `354588549c31d9fdd03a6665ec2c703912384ad6` |
| Backend merge | `e34d1cd` |
| iOS merge | `879dbbd` |
| Integration fixes | `dbd743aef038f9fff73a00abe0e6648d2891798c` |

Remote branches were fetched before integration. Backend and iOS both descend from the original main. All analytics commits are already ancestors of backend, including `3545885` through merge `908467f`. Backend also contains subsequent vehicle-model and source-isolation work. No separate analytics merge or older model copy was applied. There are 33 backend-history commits and 9 iOS-history commits beyond the base; full hashes and subjects are in [integrated commits](release/integrated-commits.txt).

Both branch merges were conflict-free. No uncommitted user changes were overwritten.

## Files and confirmed integration fixes

[Complete file manifest against main](release/files-changed.txt). Most changes are the previously separate backend, analytics/model, vehicle catalog, and native app branches.

Release-specific changes:

- `backend/services/league_demo.py`, `backend/routes/league_costs.py`, `backend/main.py`: promote the reviewed local showcase proposal into normal backend registration. Remove the proposal's route-order override mechanism, which could retain duplicate legacy handlers. Keep a single backend implementation; the iOS developer-tool adapter is now only a compatibility import.
- `backend/routes/crews.py`: exclude registered synthetic identities from the four-real-member qualification in create/join/read responses, preserving existing membership authorization and errors.
- `backend/routes/leaderboard.py`: retain the deprecated legacy improvement response for older clients, with synthetic qualification guards. Initial proposal behavior changed small genuine leagues' legacy fields; two regression failures exposed this and were fixed without weakening the original tests.
- `backend/db/004_league_demo.sql`: move the proposal schema into the backend; no duplicate schema source. It is an explicit deployment prerequisite, never an automatic seed. `backend/scripts/test-db.sh` applies it only to the local test database.
- `backend/tests/test_league_costs.py`: current-week sums, ascending order, dense ties, out-of-week/source exclusion, missing data, authentication/ownership, receipt agreement without a baseline, disabled write gates, and current/deprecated route documentation.
- `ios/DeveloperTools/league_demo/test_isolated.py`: fixed localhost release database; maintain fixture timing in the current week; stop rewriting committed offline showcase fixtures during tests.
- Root/showcase documentation and `.env.example`: explain current integration and keep demo writes off. Remove two tracked Finder `.DS_Store` files.

Byte-identical trip/vehicle fixtures exist in the root test fixtures and bundled iOS mock resources intentionally. They serve independent test/resource packaging. No competing runtime model was introduced. `drive_save_model/`, `analytics/`, backend scoring/vehicle parameter code and `repo.py` match the backend tip exactly. Native app, sensor, calibration, thresholds, telemetry, and receipt UI match the iOS tip exactly.

## Ranking and provenance contract

Current iOS requests `GET /leaderboard/costs`. It ranks the caller's current league by the sum of stored estimated avoidable fuel cost for scored **recorded-source** trips in the current UTC week (Monday inclusive, next Monday exclusive), using membership captured on the trip. Lowest cost ranks first; the highest cost is last among ranked drivers. Equal totals share a dense rank. No eligible scored trips means null cost and null rank, never invented zero. Four real members remain required. No baseline or improvement value determines this ranking.

The deprecated `/leaderboard` retains its old improvement contract for old clients. The current app never presents those old ranks as cost ranks. Existing analytics queries/progress calculations remain compatible. Improvement can remain a secondary metric.

Experimental model results continue to carry `is_demo=true` under the existing backend policy even for recorded-source trips. The new board therefore distinguishes provenance using `source='recorded'`, scored status, and the synthetic-identity registry, rather than pretending the experimental flag means a physical trip was fictional. Scientific assumptions and experimental-estimate labels are unchanged.

The five fictional players are explicitly labeled **Synthetic demo**. Example amounts stay in `drivesave_demo.synthetic_trips`, outside public trips, metrics, baseline and savings tables. The explicit `/leaderboard/demo` showcase mixes labeled examples with only actual stored scored recorded-source results for the presenter; an unscored presenter is unranked. No financial result was fabricated for any real account.

## Validation

All Python checks used Python 3.12.14 and local disposable TimescaleDB/Postgres 17, with a dedicated container `drivesave-release-test` bound only to `127.0.0.1:55440`. No production database URL or bearer token was used. The EPA catalog import loaded 74,015 test rows and 12,233 vehicles, including 10,977 with fuel parameters.

| Check | Result |
| --- | --- |
| Unchanged backend/model baseline | 150 passed; 17 catalog-dependent skips before local catalog import |
| Final backend + model + cost-ranking + CLI safety suite | **179 passed, zero skipped/failed** |
| Standalone isolated showcase API/database audit | **33 checks passed** |
| Portable Swift suites | **328 checks passed** across ten suites |
| Swift → Python recording payload compatibility | **10 generated payloads passed** (accept/reject expectations) |
| SQL schema constraints, analytics queries, model receipts | Passed on separate disposable TimescaleDB database |
| Model and both GPS storage adapters | Passed; unchanged assertion logic, transport retargeted to disposable TimescaleDB |
| Backend Docker build and packaged health/OpenAPI smoke | Passed; built and run locally only |
| Native unsigned generic iPhone SDK build | **BUILD SUCCEEDED** |
| Native simulator build and full offline UI suite | **19 passed, zero failures; TEST SUCCEEDED** |
| `git diff --check` | Passed |

The first Swift runner invocation had a Python-path setup error after its Swift suites passed; the corrected full runner subsequently passed including all payload checks. The initial integrated backend run had two legacy-response regressions; both were fixed and the complete final 179-test suite passed. The only remaining Python warning is Starlette's deprecation notice for its installed httpx compatibility client; it is not a test failure.

Cross-language/storage tests verify observed GPS bounds, valid coverage and speed accuracy, incomplete-detector rejection, detector version metadata, raw timestamp retention, scored-distance receipt/metrics agreement, vehicle-specific parameters, retries, account ownership, and rejection/rollback. Scoring remains server-generated. UI and view-model checks verify account/vehicle persistence, receipt decoding, error/unavailable states and synthetic showcase labeling.

UI tests explicitly excluded `RemoteAuthenticationTests` and `LiveCalculationTests` to prevent production registration/requests. The walking-route check passed after granting simulator location and supplying its documented simulated walking route; this is OS-injected location, not physical GPS validation. No live production smoke tests were run.

Local evidence: `/tmp/drivesave-release-tests.log`, `/tmp/drivesave-release-isolation.log`, `/tmp/drivesave-release-swift.log`, `/tmp/drivesave-release-payload.log`, `/tmp/drivesave-release-storage.log`, `/tmp/drivesave-release-image.log`, `/tmp/drivesave-release-device-build.log`, `/tmp/drivesave-release-ui.log`. Swift suite logs: `/tmp/drivesave-recording-tests.3AWT0v`. Simulator results: `/tmp/DriveSaveReleaseBuild/Logs/Test/`.

## Deployment prerequisites and blockers

Do not deploy merely by merging this PR. Existing Docker/Caddy configuration remains; no host/domain/secret was changed.

1. Review/apply `backend/db/004_league_demo.sql` against the intended database before enabling this backend. Core analytics schema remains v4. No seed is part of this migration. Cost and crew routes require the new registry even when empty.
2. Review runtime-role access separately. If using the restricted `drivesave_app` role, it needs schema usage and read access for the new demo registry/read routes. Existing `app_role.sql` does not grant these; it was deliberately left unchanged. Without reviewed grants, this is a deployment blocker, even though tests using the disposable local owner pass. The initial bundled grant edit was rejected by automatic approval review as an unapproved privilege expansion; no production or persistent role grants were made.
3. Keep `DRIVESAVE_ENABLE_LEAGUE_DEMO_WRITE=0` and `DRIVESAVE_DEMO_PRESENTER_ID` empty. Production seeding is not required for the offline demo. Any future remote showcase write/cleanup requires a separate approval, exact presenter UUID/league verification, and narrowly reviewed write/delete permissions. No such permissions or approval are assumed here.
4. Build/deploy the API and matching iOS release only through the normal reviewed release process. Verify migration/role health before directing users to the new version. Do not run destructive test suites against Tiger Cloud.

The six-player demo is **local-only**: bundled offline fixture plus isolated localhost validation. No real Htoo account was inspected, seeded, renamed, or modified. Remote six-player showcase readiness is unverified and must not be advertised as deployed.

Physical iPhone on-road GPS quality, sensor alignment/calibration, interruption behavior under actual driving, signed device installation, network transitions, and a full physical recording → deployed Tiger → device receipt round trip remain unverified by this release run. The app retains its existing foreground recording limits and experimental model status. No available passing simulator/model test establishes fuel-accuracy claims.

All available critical local checks pass. The release branch is ready for a review PR into main. Main must remain unmerged pending human review of this report; deployment/remote-demo prerequisites are not waived by the passing local suite. Remote tips were fetched again after testing and still match the exact inputs above.

## Reproducing validation

Use Python 3.12 with `backend/requirements-dev.txt` and `httpx` for the standalone ASGI showcase audit. Initialize a disposable TimescaleDB with `analytics/schema.sql`, `analytics/queries.sql`, `backend/db/002_event_details.sql`, `backend/db/003_vehicle_catalog.sql`, and `backend/db/004_league_demo.sql`; load the repository vehicle catalog with `backend/scripts/load_vehicles.py`. Never supply a production database to pytest (its fixtures truncate tables).

```sh
# Local disposable DB only. Match the fixed standalone audit target on port 55440.
TEST_DATABASE_URL=postgresql://postgres:release-local-test@127.0.0.1:55440/postgres \
  PYTHONPATH=.:backend python -m pytest backend/tests tests/model ios/DeveloperTools/league_demo/test_cli.py -q
python ios/DeveloperTools/league_demo/test_isolated.py "$PWD"
PYTHON=python bash ios/Tests/run_recording_regressions.sh "$PWD"
xcodebuild -project ios/DriveAndSave.xcodeproj -scheme DriveAndSave \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

For ordinary offline UI tests use the simulator command in `ios/README.md`, excluding both production suites and `WalkingGPSRouteTests`. Run the route suite separately after granting location to the simulator test app and starting `simctl location DEVICE start --speed=1.4 --interval=1` with two nearby walking waypoints; clear the injected location afterwards. The release run included all 19 local UI tests, with the route prerequisite supplied for the final route test.
