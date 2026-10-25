# Genuine recording contract and integration handoff

## Scope and source contracts

All changes are in `/ios` on branch `ios`. Backend and analytics were fetched and inspected read-only:

- `origin/backend`: `5094a01bb2844cfd9819ad8b8ec55f13dc26acf5`
- `origin/analytics`: `354588549c31d9fdd03a6665ec2c703912384ad6`

The current contract is **vehicle-fuel-v2 / observed-gps-window-v1**. Current documentation lives at root `docs/api.md`, `docs/gps-scoring-window.md`, and `docs/cost-model.md` in those branches. Inspected request validation, cost-model adapter, estimator, trace validation, crew authorization and source isolation. The two branches' `drive_save_model` trees match. No assumption is made about the deployed server version.

## GPS eligibility

`GPSScoringWindow` replaces the obsolete one-microsecond endpoint requirement. Every submitted observation remains inside the original button-to-button interval. At least two distinct valid observations are required: finite speed 0–53.6448 m/s, finite speed accuracy 0–2 m/s. The first and last valid observations must be within three seconds of Start/Stop (the backend's one-microsecond numerical tolerance is retained).

Original button timestamps, GPS measurement timestamps, speed values and sequence numbers are retained. iOS does not insert endpoints, shift readings, trim events or replace measured distance with a speed-derived estimate. Existing unavailable-sensor normalization remains null, never zero.

This is deliberately a preflight. The backend still decides minimum scoring duration, interior gaps, direct time coverage, speed physics, distance agreement, events and financial eligibility. In particular, backend direct coverage is at least 95% of the **original button interval**, despite scoring only between the first and last valid GPS observations. A short recording can therefore pass local edge checks and still be refused honestly. Receipts display the server's coverage label, notes and GPS-covered distance when supplied; no local money is calculated.

## Detector completeness — authorized contract correction

**The project owner explicitly approved observed GPS-window semantics.** The newest shared `docs/gps-scoring-window.md`, rule 8, still says completeness refers to the original session. Backend/analytics must correct that documentation and coordinate rollout before relying on this iOS interpretation. Proposed replacement:

> `events_complete` asserts actual calibrated detector monitoring over the observed GPS scoring window (first through last valid GPS speed observations), not unobserved button edges. Actual motion observations must bracket that window, with no unexplained gap over one second. Deliberate low-speed classification suppression counts only while motion continues and GPS speed is valid and no more than three seconds old. Unknown or interrupted monitoring is incomplete.

The executable estimator already scores the observed GPS interval and gates on the completeness boolean and matching nonempty version; it does not inspect raw IMU coverage. No backend executable change is needed to accept the JSON, but the shared semantic agreement/documentation is required. A future server-side evidence audit would need an agreed additional schema; none is invented here.

On iOS, actual Core Motion uptimes are persisted as eligible/ineligible runs. Completeness requires observations before/at the first GPS time and after/at the last GPS time, no ineligible observations inside that window, no sampling gap over one second intersecting it, and no genuine interruption or calibration failure. Coverage is not inferred from an empty event list. A red-light stop can remain complete with actual motion samples and fresh valid low-speed GPS. Missing/stale/invalid GPS cannot establish a stationary stop. Missing motion cannot establish monitoring.

The session and all events must have consistent detector versions. New sessions use `ios-0.3.0` because monitoring eligibility changed; detector thresholds, sampling frequencies, event smoothing and financial equations did not change. Legacy records without coverage/version metadata remain unknown and cannot gain completeness retroactively. `events_complete` and `detector_version` are uploaded from the saved session. Walking tests and generated simulator sessions never assert genuine detector completeness.

## Partial GPS warning diagnosis

The old recorder latched GPS unavailability forever after a temporary location error or initial timeout. It also treated an advisory location error as a permanent detector interruption and only excluded distance over gaps longer than ten seconds. Those paths could explain an overpersistent partial warning even after reception recovered.

The recorder now tracks first/last reliable position measurement times and maximum interior gap. Waiting for the first fix has a waiting state; no usable fix/distance stays unavailable. A first reliable fix more than three seconds after Start, a trailing gap over three seconds, or a real interior gap over three seconds honestly marks partial distance. GPS gaps over three seconds reset the distance anchor and contribute **no interpolated mileage**. Temporary callback errors alone do not latch partial status or invalidate detection; actual missing/stale GPS still makes affected motion observations ineligible. Permission loss and genuine app/motion interruptions remain failures.

Position quality and speed quality are separate: position accuracy must pass the existing 35 m distance filter; speed must independently pass the stricter backend accuracy rule for monitoring/scoring. A valid position with unavailable speed can contribute honest position distance but cannot establish detector completeness. The new saved startup/trailing/maximum-gap diagnostics are available only under Developer Mode.

The reported stationary and 0.04 mi / 1:07 walking tests have no raw exports in this workspace. Their precise historical cause cannot be established from the summary alone. Stationary unavailable speed and near-zero gravity-corrected acceleration are plausible; zero distance earns no estimate. A walking distance proves neither driving eligibility nor GPS speed quality. Walking remains excluded from driving uploads and league scoring.

## Private league and account integrity

Only **GET /crews/{id} → 403 with code `forbidden`** clears that account's cached private league ID and standings, persists the removal and presents create/join. Credentials are preserved. Other statuses, other 403 codes and leaderboard refusals do not clear membership. `409 mixed_trip_sources` explains that recorded and synthetic/replayed trips require separate accounts and directs demos to isolated Test Calculation.

Starting account, server scope, confirmed full vehicle row and client trip UUID remain frozen at Start. Genuine uploads validate the owner before network access, use the saved vehicle, disallow silent account recovery/substitution and preserve the request UUID/body on retries. Old recordings without starting metadata stay local and inspectable. Synthetic Test Calculation retains its compatible fixture, separate account and receipts. No server delete or production mutation is introduced.

Two existing backend concerns remain:

- The vehicle PUT → trip POST contract uses an account-wide vehicle. A per-trip vehicle identifier/version or atomic snapshot reservation is needed to eliminate another-device changes between those requests. iOS cannot solve that race with unsupported fields.
- `DEMO_ONLY` currently changes experimental result status server-side. Genuine wire provenance stays `source=recorded, is_demo=false`; iOS never relabels a physical recording synthetic. Coordinate experimental receipt/progress/league semantics with backend. Do not assume deployment or eligibility from offline model scoring.

## Live telemetry and consumer UI

The existing black/lime telemetry display remains unchanged: display-only smoothing at 2 Hz, signed gravity-corrected values, calibrated vehicle axes only when mounting is valid, device axes otherwise, stale/invalid values as “—”, no continuous VoiceOver announcements. No sensor frequency or detector threshold changed. Pre-drive and recording safety warnings remain. Insufficient data receipts retain the concise consumer state and actual technical reason in Developer Mode.

## Reproducible offline verification

```sh
bash Tests/run_recording_regressions.sh
python3 Tests/check_recording_compatibility.py --backend /path/to/read-only/backend-snapshot
```

The Swift recording suite uses the actual `TripUploadBuilder` and `APIJSON` serializer to write ten controlled fixture payloads to `/tmp/drivesave-recording-contract`. Existing Test Calculation fixture measurements are reused unchanged for positive edge cases. Explicit negative fixtures remove observations or mark accuracy insufficient; these are controlled synthetic tests, never manufactured physical evidence. Test completeness metadata is stipulated in those fixtures; real recorder completeness is independently tested from actual observation-run logic.

The Python probe uses the fetched backend's `TripCreate`, `build_input` and real estimator. It mirrors the backend's existing `DEMO_ONLY` transform **in memory only**, preserving the original JSON/provenance. Five positive cases cover exact/realistic/asynchronous/three-second boundaries and recorded-mode serialization. Five negative cases cover excessive edge gaps, sparse coverage, interior gaps, inaccurate speed and incomplete event detection; refusals must contain no money or fuel result. No fixed financial amount is asserted or invented. No network, database or production data is used.

A physical Developer Mode export can be inspected read-only:

```sh
python3 Tests/check_recording_compatibility.py --backend /path/to/backend-snapshot --recording /path/to/export.json
```

Native offline UI regression command (live suites excluded to avoid production mutations):

```sh
xcodebuild -project DriveAndSave.xcodeproj -scheme DriveAndSave \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -derivedDataPath /tmp/DriveSaveTelemetryBuild -parallel-testing-enabled NO \
  -skip-testing:DriveAndSaveUITests/WalkingGPSRouteTests \
  -skip-testing:DriveAndSaveUITests/RemoteAuthenticationTests \
  -skip-testing:DriveAndSaveUITests/LiveCalculationTests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

See `FinalIOSIntegration.md` for verified results and file summary. Physical iPhone/car validation against the deployed compatible backend remains required: mounted calibration, genuine CM/GPS cadence/accuracy, stop-and-go traffic, startup/tail coverage, GPS dropout, speed/position distance agreement, clock mapping, interruptions, selected vehicle, owner isolation and the real receipt/league outcome. Offline scoring proves compatibility, **not** the complete physical driving-to-receipt pipeline.
