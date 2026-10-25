# Test Calculation

Open **Home → Profile → My Vehicle → Test Calculation** in online mode after saving a vehicle. The button starts a synthetic/demo test; no driving or phone movement is required.

## Flow and safeguards

1. Snapshot the driver's current saved vehicle. Local-only JSON drafts must be uploaded first. Offline mode cannot silently run a mock calculation instead of the real server action.
2. Download the current public backend branch's `fixtures/sample-trip.json` through URLSession, without any API token. Cache bypass is requested. Failure never falls back to a bundled fixture.
3. Generate a fresh `client_trip_id` and fresh `events[].event_id` UUIDs for the new logical test. Set `source: synthetic` and `is_demo: true`. Preserve the sample's detector version, `events_complete`, event types, durations, peak g, headings, timestamps, speed samples, sample sequences, accuracy, distance, and average speed. No observations are created or repaired.
4. Reject missing required metadata, missing speed samples, invalid payloads, and coordinate-bearing samples. Never assert detector completeness for an ordinary recording just to get a receipt.
5. Register/restore a **separate calculation identity** in a dedicated Keychain namespace scoped to the real driver and server. A client role guard and driver-ID collision check prevent using the normal identity. Calculation clients cannot create or join leagues.
6. Use the existing API client's authenticated vehicle PUT → trip POST → receipt GET. Copy the exact selected vehicle object, including its catalog ID and unknown fields.
7. Display the returned receipt. The authoritative pricing car is **`receipt.vehicle`**, not the selected-car title. A missing field says “Not reported by server.” Unsupported/free-form profiles may be priced as the server's reference car; the UI does not label those cars eligible for real estimates.

Trip/event identities remain unchanged for **Retry**, including after an ambiguous POST network failure (the backend's duplicate 200 response is reused). A receipt-only retry retains the server trip ID and does not submit another trip. **New Test** fetches the latest sample again and creates new identities. These results are not added to driving history, Home totals, or the real driver's uploads/baseline/league.

### Why event IDs are also refreshed

The deployed schema uses `PRIMARY KEY (ts, event_id)` for `trip_events`, without `trip_id` in that key. Reusing the sample's fixed event IDs after a successful first test caused HTTP 500 collisions. New event UUIDs avoid that collision while every detector/GPS measurement and timestamp stays identical to the sample. Retries reuse the same event IDs so idempotency is preserved. No backend/schema changes were made.

## Financial presentation

The amount is the server's `avoidable_cost_usd`, labeled **Estimated avoidable fuel cost**. It is not the entire trip's fuel bill or measured savings. The screen also shows:

- `vehicle`: the actual server pricing car
- `cost_model`: the unmodified model/version name
- `label`: the server's accuracy disclaimer (or an explicit unvalidated-estimate fallback)
- `assumptions`: values, units, estimate markers, source links, and dates
- `notes`: nonnumeric assumptions returned by the server
- `high_speed_cost_usd`: the returned high-speed portion, when present

No fuel math runs in Swift. `flat_per_event` receipts retain their prominent placeholder-pricing warning. All results remain labeled synthetic/demo, and a non-demo or wrong-trip receipt is rejected.

`trip_not_scored` shows **Trip not scored**, the backend's reason, and no amount. It is distinct from a UUID conflict. New Test requests another current fixture; it does not fabricate data to satisfy the model. Other errors show the failed stage and Retry.

## Contract and fixtures

Inspected backend branch commit [`0f5208cb9ff50c898cd560618ce6a63bca1c16c3`](https://github.com/RamboHtoo/drive-save/tree/0f5208cb9ff50c898cd560618ce6a63bca1c16c3):

- `docs/api.md`
- `backend/models/trips.py`, `backend/models/cost_model.py`
- `backend/services/cost_model.py`, `backend/repo.py`, `analytics/schema.sql` (read only)
- `fixtures/sample-trip.json`, `fixtures/sample-receipt.json`

`MockData/Backend/calculation-trip.json` and `calculation-receipt.json` are captured upstream fixtures for deterministic tests only. The sample has 301 speed readings spanning its five-minute trip. Existing older replay fixtures remain unchanged for compatibility. Runtime Test Calculation always downloads the backend's latest sample.

The wire models add optional detector-completeness fields and optional receipt vehicle/label/high-speed/notes fields. Old cached uploads and receipts still decode. Existing recorded trips do not automatically receive `events_complete: true` or an invented detector version.

## Verification commands

Mock checks first:

```sh
swiftc -module-cache-path /tmp/drive-save-module-cache \
  DriveAndSave/Models/{DrivingModels,RecordingModels,BackendModels,VehicleCatalogModels,TestCalculationModels}.swift \
  DriveAndSave/Services/{TripUploadBuilder,KeychainCredentialStore,BackendAPIClient,TestCalculationService}.swift \
  DriveAndSave/ViewModels/TestCalculationViewModel.swift Tests/TestCalculationTests.swift \
  -o /tmp/drivesave-calculation-tests
/tmp/drivesave-calculation-tests
```

The 50 checks include sample fidelity, fresh trip/event identities, retry identity preservation, vehicle PUT ordering, isolated authentication, no league endpoints, response metadata, receipt-only retries, and unscored/error handling.

`Tests/TestCalculationLiveSmoke.swift` is opt-in. Compile with the model/service sources above (omit the view model and replace the test file), then pass `--live`. It creates only an isolated demo account, uses a real 2020 Toyota CAMRY catalog object, submits a synthetic sample, fetches the receipt, and verifies an identical retry returns the same trip. Credentials remain in memory and are never printed. No existing driver or league is modified. Dedicated test accounts/trips remain on the server.

The live UI test creates a new QA driver plus a distinct calculation account; it never joins either to a league. It is skipped unless explicitly enabled:

```sh
TEST_RUNNER_DRIVE_SAVE_LIVE_CALCULATION=1 xcodebuild \
  -project DriveAndSave.xcodeproj -scheme DriveAndSave \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UUID>' \
  -only-testing:DriveAndSaveUITests/LiveCalculationTests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

Routine offline test commands exclude this class. The UI flow checks the saved-car picker, Test Calculation, demo label, actual pricing car, returned amount/model, expanded assumptions, secondary navigation, and unchanged real driver nickname/vehicle.

## iPhone check

1. Run the signed app on your iPhone and sign in online.
2. Profile → My Vehicle: choose and save your actual catalog vehicle.
3. Tap Test Calculation. Keep the app open while the backend sample and receipt load.
4. Verify Synthetic / Demo, selected car, **Vehicle used for pricing**, amount, model, and How it’s calculated. A reference car returned by the server must never be presented as your selected car.
5. Tap New Test for a fresh calculation. For a connection error, Retry keeps the previous test UUID and data.
6. Return to Profile/History/Leagues: the driver's identity and car remain, and no synthetic calculation is added to driving history or real standings.

Automated simulator/API checks do not claim physical-iPhone or real-driving fuel accuracy.

## Final results (2026-10-24)

- Simulator builds succeeded.
- 50 new calculation checks plus 30 vehicle-catalog, 34 backend/auth/serialization, and 34 sensor/GPS/persistence checks passed: 148 total.
- All 13 existing offline UI tests passed on iPhone 17 Pro Max. The live calculation UI test passed on iPhone 17e: 14 distinct UI tests in total.
- Live isolated calculation and identical retry succeeded after refreshing event identities. The server priced a 2020 Toyota CAMRY as **2020 Toyota CAMRY**, returned **$0.0624** for that synthetic sample, model `notion-mazda5-2012-auto-v1`, 10 numeric assumptions, and 3 notes. This is a backend demo estimate, not measured fuel use or achieved savings.
- The UI test verified actual pricing vehicle, estimate/model, expanded assumptions, and the unchanged QA driver's nickname/vehicle after returning to Profile. No test identity joined a league; no real user's data was modified.
- [Verified synthetic receipt screenshot](DesignPreviews/test-calculation.png).
- No backend or analytics file was modified. All added/edited source, fixtures, tests, and documentation are inside `/ios`.
