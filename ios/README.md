# Drive Save — iOS

Native SwiftUI app, iOS 17+, carbon black / acid lime / warm white design. Work stays inside `/ios`.

## Run

Open `DriveAndSave.xcodeproj`, choose the **DriveAndSave** scheme and an iPhone under **Simulators**, then ⌘R. For a physical iPhone, choose your signing team/device. No external packages are required. Remote sign-in requires a signed app with generated Keychain entitlements; use normal Xcode Run, not CODE_SIGNING_ALLOWED=NO.

Root destinations: Home, Leagues, History, using an intrinsic-height safe-area navigation rail. Secondary screens have no primary navigation bar. Home costs/charts remain clearly labeled demo data. Local trips and walking tests persist across app restarts.

## Walking and driving

Home → Start Trip → choose **Walking Test**, **Driving**, or **Demo Drive**.

Walking Test uses Core Location only; no mount/calibration, driving events, or fuel estimates. Allow When In Use and Precise Location, walk outdoors for 1–2 minutes with the recording screen open, then stop walking and save. History hides Walking Tests by default; enable **Include Walking Tests** to view them. They never enter driving upload or league scoring.

Driving requires a securely mounted, flat phone, screen up and top edge forward. Calibrate while parked, then start before moving. Orientation changes disable detection. Candidate driving events remain unvalidated. Demo Drive generates synthetic inputs and is labeled accordingly.

All recording is foreground only. Locking or leaving the app ends capture; return to save. Unsaved sessions may be lost on process termination. Do not interact while driving. GPS quality, gaps and incomplete measurements are shown. The root rail uses safeAreaInset, with a vertical layout at accessibility text sizes. Home has a safe-area masthead. Secondary screens use native back navigation; recording has no main navigation rail. Final messages and save controls stay scrollable without floating overlays.

## Backend setup

First launch shows **Welcome to Drive Save**. Enter a nickname and tap **Join Drive Save** to register against `https://drivesave.nuhylabs.com`. Remote multiplayer is the default; **Offline demo** is an explicit separate mode. No vehicle setup is required to join a league.

The returned token, user ID, nickname, and recovery preference are saved in device-only Keychain. Restarting restores the same identity without another POST /users. Nicknames are not passwords or account lookup keys. Each iPhone registers its own identity. Optional development demo recovery performs one replacement registration on a 401 and shows a reset alert; ordinary accounts are preserved on a 401.

Home → **Profile** shows your nickname, user ID, league membership, refresh and invitation controls. It also lets you switch between online and offline accounts without visiting API & Vehicle. Registering a different nickname requires **Reset test account…** and confirmation. This clears only the selected mode’s local sign-in; it does not rename/delete the previous server account or delete local trips. There is no nickname-based sign-in or account recovery endpoint.

Home → **API & Vehicle** (or Profile → Vehicle & advanced settings) remains available for vehicle configuration and technical testing:

1. Import your complete selected EPA vehicle JSON, or load the explicitly labeled backend EPA example. Save selection and optionally Upload vehicle / Fetch server vehicle. Confirm a row matches your actual vehicle before real uploads. No invented car data or full EPA catalog is included.
2. Open an eligible trip receipt → **Upload / retry & fetch receipt**. Old/incomplete trips explain why they cannot upload; no missing evidence is fabricated. The stable UUID, payload, and vehicle are preserved for retries. API payloads never include coordinates.
3. To demonstrate without a car, choose **Upload / retry demo replay** in API & Vehicle. It uses the backend’s sample trip with `source: replayed`, `is_demo: true`, under a separate isolated replay account that cannot join leagues. It does not affect the normal driver’s rankings.

The current server's flat-per-event prices are labeled **PLACEHOLDER PRICING**, not measured fuel waste. Actual response fields, assumptions, source links and estimate/demo markers appear on receipts. Network errors support manual retry, duplicates reuse the original receipt, conflicts stay visible, and validation errors show field details. Uploads are never automatic.

**Server limitation:** the current scoring service counts demo trips in a user's progress. This app isolates replay credentials; server-side filtering still needs a backend fix. No backend or analytics files were changed.

## Leagues

Drivers compete individually inside a private league. Create League joins you automatically; Join League requires both league UUID and invite code from the shared invite. Joining changes your membership on the backend. At least four members are required for ranks. Drivers without a complete baseline show “Awaiting baseline.” Offline standings are fictional and labeled. There is no crew-against-crew UI.

The backend changed its leaderboard response during integration. The app follows the re-fetched source and live OpenAPI (user_id/nickname, nullable rank/improvement, league-level demo flag). See [Backend integration details](Docs/BackendIntegration.md) for exact behavior, model comparisons, file inventory and remaining limits.

## Four iPhone multiplayer check

1. Install and run the signed app on each phone. Each person enters their own nickname on Welcome, leaves Offline demo **off**, and taps Join Drive Save. Existing offline users can choose Profile → Use online multiplayer.
2. Person 1 opens Leagues → Create League, enters a name, then taps Copy invite or Share invite. The full invitation contains both the UUID and code required by the existing API.
3. The other three open Leagues → Join League, paste the full invitation (or enter the UUID and code), then tap Join League.
4. Everyone pulls to refresh Leagues or taps Refresh league & drivers. Expect all four driver names, member count 4, and the same league. Restart the app and check Profile: the nickname, user ID, and membership should remain the same.
5. Drivers without eligible real driving baselines remain unranked / Awaiting baseline. You can test registration, membership, sharing and refresh without a car. Walking Tests and demo replays do not supply real ranking evidence.

Offline demo is local to one phone and cannot be used for this multiplayer check. Never reset another tester’s account to make the count change; reset only your own disposable test sign-in intentionally.

## Checks

Offline UI tests select offline onboarding in isolated test account namespaces; simulator location should be denied or fresh:

```sh
xcodebuild -project DriveAndSave.xcodeproj -scheme DriveAndSave \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -derivedDataPath /tmp/DriveAndSaveBuild -parallel-testing-enabled NO \
  -skip-testing:DriveAndSaveUITests/WalkingGPSRouteTests \
  -skip-testing:DriveAndSaveUITests/RemoteAuthenticationTests CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

WalkingGPSRouteTests requires granted simulator location and an active `simctl location ... start` walking route; this checks the Core Location code path, not physical accuracy. RemoteAuthenticationTests is opt-in: it uses the actual remote welcome flow to register a dedicated test driver and verifies the same user ID after relaunch, with a separate test credential namespace.

Portable checks:

```sh
swiftc -module-cache-path /tmp/drive-save-module-cache \
  DriveAndSave/Models/{DrivingModels,RecordingModels,BackendModels,TripExportPayload}.swift \
  DriveAndSave/Services/{TripStore,APIClient}.swift DriveAndSave/MockData/DemoData.swift \
  Tests/main.swift -o /tmp/drive-save-model-tests-runner
/tmp/drive-save-model-tests-runner

swiftc -module-cache-path /tmp/drive-save-module-cache \
  DriveAndSave/Models/{DrivingModels,RecordingModels,BackendModels,LeagueInvitation}.swift \
  DriveAndSave/Services/{TripUploadBuilder,KeychainCredentialStore,BackendAPIClient}.swift \
  DriveAndSave/MockData/DemoData.swift Tests/BackendTests.swift -o /tmp/drivesave-backend-tests
/tmp/drivesave-backend-tests
```

`Tests/LiveLeagueSmoke.swift` is a separate opt-in four-account multiplayer check. It registers four dedicated test drivers, creates a new league, joins all four, checks restored identities/member lists/leaderboards, and sends no trips or reset/delete requests. Compile with the same backend source files (replace `Tests/BackendTests.swift` with `Tests/LiveLeagueSmoke.swift`) and run only when live testing is intended. Its dedicated test league remains on the server.

`python3 Tests/production_smoke.py` is an explicit live test that creates only dedicated test users and an inactive test league. It never logs/writes tokens or resets/deletes existing data. Do not run it as a routine offline unit test.

Physical driving accuracy and uninterrupted background recording are not validated or claimed. The full EPA catalog, automatic background sync, and a real financial cost model remain outside this implementation.

## Integration verification

- Signed simulator remote registration and Keychain restoration passed using a dedicated demo user in an isolated test credential namespace.
- 34 existing model/GPS/persistence checks and 25 contract/serialization/HTTP checks passed.
- Offline API registration, complete EPA fixture, replay, placeholder receipt and inactive-league UI flow passed. Existing driving denial, recording interruption, simulated recording and history UI flows passed.
- Production health, registration, vehicle PUT/GET, replay 201, duplicate 200, conflict 409, validation 422 with details, invalid-token 401, receipt, league create/join/get and the updated member leaderboard were verified using dedicated disposable test users only.
- Production testing confirmed the demo-scoring gap described above. Replay identities were never added to a league; test leagues were left inactive. No reset/delete endpoints were used and no credentials were logged.

All eight distinct UI flows passed in batches, including Walking Test filtering/persistence, save-button clearance and the final Core Location route. The production Swift client was also exercised end-to-end with `Tests/LiveClientSmoke.swift`, using only dedicated disposable accounts and an inactive test league. Full results and test limits are recorded in [BackendIntegration.md](Docs/BackendIntegration.md).

## Onboarding verification (2026-10-24)

- Signed simulator builds passed; welcome/Profile/reset and footer-layout checks passed on iPhone 17e and iPhone 17 Pro.
- 34 model/GPS/persistence regression checks and 34 backend contract/auth/invitation checks passed.
- Nine distinct UI flows passed in batches: welcome/persistence/reset; Leagues footer layout; vehicle/replay/league; four driving flows; remote welcome/Keychain relaunch; Walking Test persistence/filtering/unchanged standings. The initial reset confirmation popover lacked a visible Cancel action on the test runtime; it was replaced with an explicit Cancel/Reset alert and the flow passed.
- Live API checks passed with four new dedicated accounts in one league, member counts 1→4, unique/restored user IDs, matching member leaderboards, and no invented ranks. No trips were uploaded by those four accounts.
- Four physical iPhones and real driving baselines were not tested here. Home financial charts remain demo data; recording accuracy and the server cost-model limitations above remain unchanged.

## Visual redesign

Home, Leagues, and Trip Receipt were redesigned and verified as separate stages. See [VisualDesign.md](Docs/VisualDesign.md) for tokens, behavior, modified-file inventory, verification results, and remaining visual scope. Reusable components provide scaled condensed system typography, strong-contrast primary actions, ruled sections, an original Canvas lane illustration, honest GPS observation charts, compact individual standings, and a warm-white itemized receipt. Demo/pending/placeholder financial disclosures remain explicit. Existing authentication, Core Motion, Core Location, trip serialization, persistence, scoring, and backend contracts are unchanged.
