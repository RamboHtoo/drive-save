# Genuine recording contract and handoff

Changes are limited to `/ios`. No backend, analytics, pricing equations, production accounts, trips, or league data were changed. Test Calculation still uses its existing compatible synthetic fixture and isolated account.

## Source contracts inspected

Fetched `origin/ios`, `origin/backend`, and `origin/analytics` before implementation:

- backend: `11c6fcc335e81d45ec7c3715385d10db548c8f07`
- analytics: `9c92a841d9c3af8753787daa639298fd635bb42a`
- iOS starting point: `e0fdd6a7ccc4544cce002cee897fe66ce02c5738`

Inspected backend `models/trips.py`, `services/cost_model.py`, `repo.py`, API/model documentation, and both branches' `drive_save_model/trace.py` and `estimator.py`. Both trace implementations require valid GPS speed readings within **one microsecond** of both scoring boundaries, no gap over three seconds, at least 95% direct time coverage, and integrated speed distance within 10% of the submitted distance. A valid speed includes speed accuracy of 0–2 m/s. The estimator also requires explicit complete event detection and matching nonempty session/event detector versions. An empty event list alone is not evidence of completeness.

The backend branch contains a newer vehicle-specific estimator than analytics' Mazda5-specific estimator. The executable compatibility test uses the backend branch's actual request validator, adapter and estimator together; do not substitute analytics' older estimator into the newer backend without reconciling their vehicle/configuration interface.

## Implemented on iOS

- `RecordingDetails` now persists `eventsComplete`, `detectorVersion`, and detector coverage evidence. Missing legacy fields remain unknown. `TripUploadBuilder` emits explicit `events_complete: false` for unknown sessions and emits the actual saved version for new device sessions, including sessions without detected events.
- Coverage uses actual Core Motion observation uptimes. Startup and shutdown gaps remain incomplete; motion gaps, unavailable/paused detection, mount changes and interruptions invalidate the session. The existing detector's low-speed/GPS suppression is conservatively treated as incomplete; this change does not assert that stationary suppression constitutes a complete observation.
- The installed detector retains version `ios-0.2.0`; thresholds and financial calculations were not changed. A session's version is saved even if it produced no events. Old recordings are never assigned a version retroactively.
- Wire timestamp encoding/decoding retains microsecond precision supported by the Python contract; the former ISO formatter reduced observations to millisecond precision. Millisecond-aligned fixture timestamps keep their existing representation. No timestamp is moved to another sample or boundary.
- Core Motion's original uptime is retained. Its wall-clock observation time uses the recording's clock anchor instead of callback delivery time. Pre-start queued motion observations are excluded. Core Location timestamps and readings are unchanged.
- End time and elapsed duration are frozen when recording ends, including foreground interruptions. Returning later and tapping Save cannot extend the trip's scoring interval.
- At Start, `Trip` captures an immutable local `RecordingContext`: account UUID, server/offline scope, full selected EPA vehicle row and confirmation state. No token is stored in that context or sent with trip data. Changing Profile afterward cannot reassign the saved recording's vehicle or owner.
- Genuine uploads require the starting account, matching server scope and a confirmed supported starting vehicle. Legacy recordings without a starting snapshot remain inspectable locally; they cannot be assigned today's account or vehicle on first upload.
- Genuine uploads and receipt fetches enforce the expected owner before/after asynchronous requests and disable automatic account replacement on 401. Cached genuine receipts are also owner scoped. Synthetic demo recovery and Test Calculation identity isolation remain intact.
- New uploads use the starting vehicle snapshot in the existing vehicle PUT → trip POST sequence. The trip JSON contract has no per-trip vehicle parameter; atomic vehicle binding across multiple devices remains a backend contract concern (below).
- Local preflight blocks known missing boundary readings and incomplete/unknown detector coverage before upload. It neither trims the interval nor inserts endpoint readings. Remaining GPS quality and model eligibility rules remain authoritative on the backend.
- Receipts show **Insufficient recording data** for data that cannot be scored. A server `trip_not_scored` response is retained per upload without a fallback amount, survives relaunch, and appears as the same concise state. The exact response/reason, coverage, session version and starting context are available through Profile → Developer Mode → Developer tools → History & receipt diagnostics. Receipts without a server result show the recorded vehicle; server receipts retain the actual pricing vehicle from the server.
- Existing incomplete-distance labels, local inspection/deletion confirmation, safety warnings and backend/demo tools are preserved. Local deletion never invokes a server endpoint.

## Genuine scoring remains blocked — requested teammate contract

Current iPhone recording boundaries are button-tap times. Sensors report discrete observations after Start and before Stop. GPS does not honestly provide a reading at either arbitrary button instant, and detector startup/shutdown/pauses do not constitute coverage of the entire button interval. There is no supported iOS-only correction under the current contract.

Backend/analytics should agree and document the following before genuine scoring is enabled:

1. **Separate the recording interval from the scoring interval.** Retain original `recording_started_at` / `recording_ended_at` for provenance. Define explicit scoring boundaries, or a server-derived observed interval, using existing real GPS observations within actual detector coverage. Specify which interval `started_at`, `ended_at`, duration, event inclusion, and distance mean. The scoring distance must belong to that same interval, with its measurement method agreed. Do not ask iOS to relabel button times as measured GPS observations, fabricate endpoint readings, or silently trim distance/events.
2. **Define detector coverage semantics.** Agree the detector version, eligible observation interval, maximum allowed IMU gap and whether deliberate low-speed suppression is valid observation or a pause. Decide how to represent observed subintervals and unknown coverage. `events_complete` may become true only for the agreed scoring interval actually covered. Merely relaxing GPS endpoints will not fix incomplete detector sessions.
3. **Separate experimental estimate status from synthetic input provenance.** `repo.accept_trip` currently forces `is_demo=True` under `DEMO_ONLY`; the estimator rejects `is_demo=False` as `experimental_model_requires_demo_mode`. The shared schema stores experimental monetary results only on demo trips. Preserve `source=recorded` and original data provenance while defining whether/how genuine experimental trips are eligible for progress and league baselines. iOS continues to submit genuine recordings as `source=recorded, is_demo=false`; it does not disguise them as synthetic to obtain money or rankings.
4. **Bind the starting vehicle atomically to a trip.** The current API prices from the account-wide vehicle at POST time. iOS freezes the full row and performs the existing PUT first, but another device can change that row between PUT and POST, and uploading an older vehicle can change the account profile. Add an agreed per-trip vehicle identifier/version or server snapshot reservation to remove this race. No new unsupported JSON fields are sent by this change.

After the agreed contract exists, iOS can select a genuinely observed scoring interval and update detector start/stop handling accordingly. Validate real device speed accuracy, cadence, IMU continuity, GPS/speed-derived distance agreement, mount stability and clock mapping before claiming physical recordings score reliably. Current preflight intentionally leaves incompatible recordings local.

## Offline verification

Run all portable Swift regressions from `/ios`:

```sh
bash Tests/run_recording_regressions.sh
```

This compiles and runs models/storage/network, backend/auth, catalog, Test Calculation, local history and recording-contract checks. The recording suite writes JSON with the actual production `TripUploadBuilder` and `APIJSON` encoder to `/tmp/drivesave-recording-contract`. Fixture sensor readings come from the existing captured sample; none are represented as physical observations or uploaded. The recorded-mode fixture tests the genuine wire provenance path, but is still an offline fixture.

Then point Python at a **read-only backend snapshot** containing `backend/` and `drive_save_model/` with its dependencies (numpy and pydantic):

```sh
python3 Tests/check_recording_compatibility.py \
  --backend /path/to/backend-snapshot \
  --payloads /tmp/drivesave-recording-contract
```

The test validates all four Swift-generated payloads using `TripCreate`, `build_input`, and `estimate`:

- Complete replay fixture: scored by the actual model (no expected dollar amounts invented by iOS).
- Same raw GPS with an earlier recording boundary: `missing_boundary_speed`, no fuel or money.
- Recorded-mode serializer fixture with that boundary gap: same refusal, original wire `source=recorded, is_demo=false` preserved.
- Complete GPS but incomplete detector: `event_recording_incomplete`, no fuel or money.

The Python probe explicitly mirrors the backend's current `DEMO_ONLY` transformation **in memory**, after validating the original wire payload. It never changes the JSON or silently labels a production recording demo. No HTTP, database or production data is used. A real iPhone export can be inspected through the same validator/model locally:

```sh
python3 Tests/check_recording_compatibility.py \
  --backend /path/to/backend-snapshot --recording /path/to/ios-export.json
```

No physical iPhone export was available in this workspace. These checks prove serializer/model compatibility and honest refusals, not real-world detector accuracy or successful genuine scoring.

Simulator regression command (offline suites only):

```sh
xcodebuild -project DriveAndSave.xcodeproj -scheme DriveAndSave \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -derivedDataPath /tmp/DriveSaveRecordingBuild -parallel-testing-enabled NO \
  -skip-testing:DriveAndSaveUITests/WalkingGPSRouteTests \
  -skip-testing:DriveAndSaveUITests/RemoteAuthenticationTests \
  -skip-testing:DriveAndSaveUITests/LiveCalculationTests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

Live tests are excluded to avoid creating production users, leagues or trips. Simulator-generated recordings remain demo labeled. No deployment was attempted.

## Verification results for this change

- Native iOS simulator build: **BUILD SUCCEEDED** on the final source, including the microsecond codec and mandatory starting-owner guard.
- **208 portable Swift checks passed**: 34 model/storage/network, 51 backend/auth, 30 catalog, 50 Test Calculation, 21 local history and 22 recording-contract checks.
- **Four Swift → Python fixture compatibility cases passed** against backend `11c6fcc`: the actual backend validator/adapter/model scores the complete synthetic fixture and refuses the incompatible inputs without money.
- The full offline simulator run passed **14/14 UI tests**. A subsequent focused run passed **8/8**, including all six recording tests and the added starting-vehicle/profile-change/relaunch test. Together these cover **15 distinct offline UI tests**, with no failures.
- Final `git diff --check` passed. All repository modifications are under `/ios`. Live/production tests and deployment were excluded.

Logs from this session are in `/tmp/drivesave-recording-verified-regressions.log`, `/tmp/drivesave-recording-xcode.log`, `/tmp/drivesave-recording-final-xcode.log` and `/tmp/drivesave-recording-native-verified-build.log`. Simulator result bundles are under `/tmp/DriveSaveRecordingBuild/Logs/Test/`.
