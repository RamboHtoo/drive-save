# Drive Save — iOS

Native SwiftUI iPhone app for HackPSU 2026, iOS 17+. No external dependencies. All implementation lives in `/ios`; backend and analytics folders are untouched.

## Launch in Xcode

1. Open `DriveAndSave.xcodeproj` and select the **DriveAndSave** scheme.
2. Choose an iPhone under **Simulators**, not a stale “mismatched platform” Recent entry.
3. Press **⌘R**. For a physical iPhone, select your signing team in Signing & Capabilities; change the bundle identifier only if your provisioning requires it.

Home, Crew, and History retain the navy/mint mock-data experience. Start Trip opens setup → recording → stop/save → receipt. Shared scroll views include bottom safe-area clearance for the floating tab bar.

## What works

- Foreground Core Motion recording requests device-motion samples at 10 Hz. Stores timestamps, uptime, phone-frame acceleration in g, rotation rate in radians/second, attitude in radians, and calibrated/smoothed forward/lateral acceleration in m/s².
- Stationary calibration collects 20 stable readings (about 2 seconds). The phone must be secured flat, screen up, with its top edge manually aligned toward the vehicle front. Gravity projects this explicitly confirmed axis onto the horizontal plane; the app does not infer vehicle axes from phone axes automatically.
- A low-pass filter feeds provisional candidate detection: braking 2.8, acceleration 2.5, cornering 2.8 m/s²; minimum 0.5 seconds and 4-second per-type cooldown. Settings are injectable through `DetectionConfiguration`. Detection requires a recent accepted GPS speed of at least 2 m/s. Thresholds are not validated safety classifications.
- A changed mount tilt disables candidate detection. Gravity cannot detect a phone being rotated flat in its mount: keep the mounting direction fixed, and recalibrate before the next trip after changing it.
- Core Location requests When In Use permission. Rejects fixes outside 35 m accuracy, stale/future points, invalid coordinates, duplicate/out-of-order times, and jumps over 65 m/s. Distance ignores movement inside the GPS uncertainty radius and does not interpolate gaps over 10 seconds. This conservative filtering may undercount travel.
- Denied location, unavailable motion, and uncalibrated recording are supported. Receipts distinguish unavailable/partial distance and unavailable candidate detection. No GPS permission means no speed validation and no event detection.
- Raw samples, timestamps, events, quality/interruption notes, and trip provenance are saved as Codable JSON in Application Support/DriveSave/trips.json. Writes are atomic and file-protected. Saved trips reload into History; demo trips remain available. Local files are not automatically uploaded. A save failure retains the pending trip in memory and offers retry; corrupted existing storage is reported instead of overwritten.
- New recordings display **Estimate pending**. Actual fuel consumption, brake wear, and insurance costs are not measured. Demo fuel totals and chart include only the original sample estimates, excluding recordings with pending estimates.
- A parked-only debug sheet shows live raw and calibrated values.

## Foreground limitation

Leaving the recording tab, leaving the foreground, locking the phone, or an interruption that makes the scene inactive **ends recording and stops hardware**. Return to review/save the partial trip. Recording does not resume automatically. Keep the app open; do not rely on background tracking. Unsaved sessions are held in memory and can be lost if the process is terminated. Physical sensor accuracy, background behavior, and extended on-road recording have not been verified. Samples are retained in memory until saving; long-duration performance needs device testing.

## Simulator test

1. Home → **Start Trip**.
2. Turn on **Simulator test mode**. It generates synthetic motion/GPS rather than accessing sensors.
3. Confirm the parked/mounted toggle; tap **Calibrate mounted phone** for synthetic calibration.
4. Tap **Start simulated trip**; wait about 13 seconds to generate all three candidate event types.
5. Tap **Stop & save · I’m parked**. The receipt is labeled simulated with its estimate pending.
6. Open History, inspect the saved trip, terminate/relaunch, and confirm it remains.
7. Start another test, go to the Home Screen, then return. Recording should have ended; save the partial session.

## Physical iPhone test

1. Connect a developer-mode iPhone running iOS 17+, choose your team and device in Xcode, then Run.
2. While parked, tap Start Trip with simulator mode **off**. Enable location and allow While Using. For a denial test, choose Don’t Allow; you should still be able to record/save an unavailable-distance session without crashing. Permission can be changed under Settings → Privacy & Security → Location Services → Drive Save.
3. Secure the phone flat, screen up, top edge facing forward. Confirm the mount toggle and calibrate while the car remains still. If calibration times out, correct the mount and retry. Do not use an unsupported vertical mount.
4. Start recording before moving. Keep the app foreground and phone secured. A passenger may inspect debug readings while parked; the driver must not interact while driving. Never deliberately perform harsh maneuvers for testing.
5. After parking, stop/save. Confirm duration, GPS quality, candidate events, timestamps, pending financial estimate, and recorded provenance. Reopen History after relaunch.
6. Compare distance to a known route and evaluate motion readings on actual hardware. No claim of measurement accuracy is made by simulator tests. Test denied/unavailable GPS and interruptions separately while parked.

## Backend preparation

`APIClient.Mode.mock` remains the default. Inject `.live(baseURL: URL(...))` into AppViewModel to use a configurable HTTPS base URL. No keys are embedded. Provisional contracts, to be agreed with teammates:

- `GET /ios/snapshot` → `{ "trips": [...], "crews": [...] }` (camelCase Codable fields; ISO 8601 dates).
- `POST /ios/trips` → `TripUploadRequest { schemaVersion: 1, trip: Trip }`. `uploadTrip` is implemented using URLSession/async-await but is not called automatically. Authentication, server acknowledgement, deduplication, retries, analytics calculation, and real competition remain integration work.

## Files

App foundation: `DriveAndSave/DriveAndSaveApp.swift`, `Models/DrivingModels.swift`, `MockData/DemoData.swift`, `Views/CrewLeaderboardView.swift`, asset catalog and mint AccentColor.

Added for recording:

- `DriveAndSave/Models/RecordingModels.swift` — sample/event/detail models, configurable detector, GPS distance filter.
- `DriveAndSave/Services/TripRecordingService.swift` — foreground motion/GPS lifecycle, calibration, simulator source, debug state.
- `DriveAndSave/Services/TripStore.swift` — local JSON persistence.
- `DriveAndSave/Views/TripRecordingView.swift` — setup, recording, safe stop/save, debug sheet.
- `DriveAndSaveUITests/RecordingFlowTests.swift` — permission denial, foreground/tab interruption, recording, persistence and screen navigation.
- `Tests/main.swift` — portable detector, persistence, Codable and GPS regression checks.

Updated for recording:

- `DriveAndSave/Models/DrivingModels.swift` — optional recording details and quality-aware labels.
- `DriveAndSave/ViewModels/AppViewModel.swift` — merge local recordings and preserve demo-only cost totals.
- `DriveAndSave/Services/APIClient.swift` — provisional trip upload request and method.
- `DriveAndSave/Components/DesignSystem.swift` — bottom safe-area spacing and provenance-aware trip rows.
- `DriveAndSave/Views/HomeView.swift` — Start Trip and clear demo-only financial totals.
- `DriveAndSave/Views/TripReceiptView.swift` — recording quality, exact duration, candidate turns, pending costs.
- `DriveAndSave/Views/TripHistoryView.swift` — saved recordings and demo-only cost chart.
- `DriveAndSave.xcodeproj/project.pbxproj` — motion/location privacy strings and UI test target.
- `DriveAndSave.xcodeproj/xcshareddata/xcschemes/DriveAndSave.xcscheme` — shared Test action.
- `README.md` — implementation, accuracy and testing instructions.

## Automated checks

Build and UI tests (substitute an available simulator name as needed):

```sh
xcodebuild -project DriveAndSave.xcodeproj -scheme DriveAndSave \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -derivedDataPath /tmp/DriveAndSaveBuild -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO test
```

The denial UI test expects a fresh simulator location permission or an already denied permission. Reset this app's simulator location permission before running if you previously granted it. Tests save clearly labeled test sessions to the simulator app's History.

Portable regression checks:

```sh
swiftc -module-cache-path /tmp/drive-save-module-cache \
  DriveAndSave/Models/DrivingModels.swift DriveAndSave/Models/RecordingModels.swift \
  DriveAndSave/Services/TripStore.swift DriveAndSave/MockData/DemoData.swift \
  Tests/main.swift -o /tmp/drive-save-model-tests-runner
/tmp/drive-save-model-tests-runner
```

Xcode simulator compilation passed. All four UI tests passed on iPhone 17 Pro/iOS 26.4, including denied permission, foreground interruption, tab interruption, simulated recording, persistence, receipt navigation and existing tabs. Nineteen portable regression checks passed. Saved JSON was inspected to confirm synthetic acceleration/braking/turn candidates, motion samples, GPS samples and simulated provenance. No physical-device or backend validation has been performed.
