# Drive Save — iOS

Native SwiftUI app, iOS 17+, dark navy/mint design. Work stays inside `/ios`.

## Run

Open `DriveAndSave.xcodeproj`, choose the **DriveAndSave** scheme and an iPhone under **Simulators**, then ⌘R. For a physical iPhone, choose your signing team/device. No external packages are required. Remote sign-in requires a signed app with generated Keychain entitlements; use normal Xcode Run, not CODE_SIGNING_ALLOWED=NO.

Tabs: Home, Leagues, History. Home costs/charts remain clearly labeled demo data. Local trips and walking tests persist across app restarts.

## Walking and driving

Home → Start Trip → choose **Walking Test**, **Driving**, or **Demo Drive**.

Walking Test uses Core Location only; no mount/calibration, driving events, or fuel estimates. Allow When In Use and Precise Location, walk outdoors for 1–2 minutes with the recording screen open, then stop walking and save. History hides Walking Tests by default; enable **Include Walking Tests** to view them. They never enter driving upload or league scoring.

Driving requires a securely mounted, flat phone, screen up and top edge forward. Calibrate while parked, then start before moving. Orientation changes disable detection. Candidate driving events remain unvalidated. Demo Drive generates synthetic inputs and is labeled accordingly.

All recording is foreground only. Locking, leaving the app or switching tabs ends capture; return to save. Unsaved sessions may be lost on process termination. Do not interact while driving. GPS quality, gaps and incomplete measurements are shown. The scroll viewport now reserves actual space above the native tab bar so save controls do not sit underneath it.

## Backend setup

Home → **API & Vehicle**:

1. Default is offline mock mode. Turn on **Use remote backend** and Apply to select `https://drivesave.nuhylabs.com`.
2. Register a nickname. Tokens and returned user IDs are stored securely in Keychain. Existing sessions restore when applying the same remote connection. Demo accounts can recover once from 401/server resets, with a visible notice.
3. Import your complete selected EPA vehicle JSON, or load the explicitly labeled backend EPA example. Save selection and optionally Upload vehicle / Fetch server vehicle. Confirm a row matches your actual vehicle before real uploads. No invented car data or full EPA catalog is included.
4. Open an eligible trip receipt → **Upload / retry & fetch receipt**. Old/incomplete trips explain why they cannot upload; no missing evidence is fabricated. The stable UUID, payload, and vehicle are preserved for retries. API payloads never include coordinates.
5. To demonstrate without a car, choose **Upload / retry demo replay** in API & Vehicle. It uses the backend's sample trip with `source: replayed`, `is_demo: true`, under a separate isolated replay account that cannot join leagues. It does not affect the normal driver's rankings.

The current server's flat-per-event prices are labeled **PLACEHOLDER PRICING**, not measured fuel waste. Actual response fields, assumptions, source links and estimate/demo markers appear on receipts. Network errors support manual retry, duplicates reuse the original receipt, conflicts stay visible, and validation errors show field details. Uploads are never automatic.

**Server limitation:** the current scoring service counts demo trips in a user's progress. This app isolates replay credentials; server-side filtering still needs a backend fix. No backend or analytics files were changed.

## Leagues

Drivers compete individually inside a private league. Create League joins you automatically; Join League requires both league UUID and invite code from the shared invite. Joining changes your membership on the backend. At least four members are required for ranks. Drivers without a complete baseline show “Awaiting baseline.” Offline standings are fictional and labeled. There is no crew-against-crew UI.

The backend changed its leaderboard response during integration. The app follows the re-fetched source and live OpenAPI (user_id/nickname, nullable rank/improvement, league-level demo flag). See [Backend integration details](Docs/BackendIntegration.md) for exact behavior, model comparisons, file inventory and remaining limits.

## Checks

Offline UI tests (default mock mode; simulator location should be denied or fresh):

```sh
xcodebuild -project DriveAndSave.xcodeproj -scheme DriveAndSave \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -derivedDataPath /tmp/DriveAndSaveBuild -parallel-testing-enabled NO \
  -skip-testing:DriveAndSaveUITests/WalkingGPSRouteTests \
  -skip-testing:DriveAndSaveUITests/RemoteAuthenticationTests CODE_SIGNING_ALLOWED=NO test
```

WalkingGPSRouteTests requires granted simulator location and an active `simctl location ... start` walking route; this checks the Core Location code path, not physical accuracy. RemoteAuthenticationTests is opt-in: it registers a dedicated demo user and verifies Keychain restoration with a separate test credential namespace.

Portable checks:

```sh
swiftc -module-cache-path /tmp/drive-save-module-cache \
  DriveAndSave/Models/{DrivingModels,RecordingModels,BackendModels,TripExportPayload}.swift \
  DriveAndSave/Services/{TripStore,APIClient}.swift DriveAndSave/MockData/DemoData.swift \
  Tests/main.swift -o /tmp/drive-save-model-tests-runner
/tmp/drive-save-model-tests-runner

swiftc -module-cache-path /tmp/drive-save-module-cache \
  DriveAndSave/Models/{DrivingModels,RecordingModels,BackendModels}.swift \
  DriveAndSave/Services/{TripUploadBuilder,KeychainCredentialStore,BackendAPIClient}.swift \
  DriveAndSave/MockData/DemoData.swift Tests/BackendTests.swift -o /tmp/drivesave-backend-tests
/tmp/drivesave-backend-tests
```

`python3 Tests/production_smoke.py` is an explicit live test that creates only dedicated test users and an inactive test league. It never logs/writes tokens or resets/deletes existing data. Do not run it as a routine offline unit test.

Physical driving accuracy and uninterrupted background recording are not validated or claimed. The full EPA catalog, automatic background sync, and a real financial cost model remain outside this implementation.

## Integration verification

- Signed simulator remote registration and Keychain restoration passed using a dedicated demo user in an isolated test credential namespace.
- 34 existing model/GPS/persistence checks and 25 contract/serialization/HTTP checks passed.
- Offline API registration, complete EPA fixture, replay, placeholder receipt and inactive-league UI flow passed. Existing driving denial, recording interruption, simulated recording and history UI flows passed.
- Production health, registration, vehicle PUT/GET, replay 201, duplicate 200, conflict 409, validation 422 with details, invalid-token 401, receipt, league create/join/get and the updated member leaderboard were verified using dedicated disposable test users only.
- Production testing confirmed the demo-scoring gap described above. Replay identities were never added to a league; test leagues were left inactive. No reset/delete endpoints were used and no credentials were logged.

All eight distinct UI flows passed in batches, including Walking Test filtering/persistence, save-button clearance and the final Core Location route. The production Swift client was also exercised end-to-end with `Tests/LiveClientSmoke.swift`, using only dedicated disposable accounts and an inactive test league. Full results and test limits are recorded in [BackendIntegration.md](Docs/BackendIntegration.md).
