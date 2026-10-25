# Presentation Mode — iPhone demo guide

Branch: `codex/presentation-mode`, based on current main `81f93a2effc15136e79aa88febb20082ae8c4fac`. All source changes are under `ios/`.

## What is ready

One shared **Presentation Mode** switch appears at the top of Home, Leagues, Profile and History, outside Developer Mode. It changes all four display surfaces together. It does not change accounts, connection mode, credentials, stored vehicles, actual leagues, trip history, upload payloads or receipts.

Sample Home and Profile show Htoo, 2015 Audi A4, $1.42 weekly estimated avoidable fuel cost, eight trips, 63.4 miles, rank #1 of 6, and 18% less waste than the previous illustrative week. Sample League shows Htoo $1.42, Alex $1.85, Jordan $2.40, Sam $3.12, Taylor $4.30, Casey $5.75, in ascending cost order. Improvement is informational only.

The optional sample history contains eight fictional display rows with costs $0.12, $0.18, $0.09, $0.24, $0.15, $0.20, $0.11 and $0.33. Their integer-cent sum is exactly $1.42. Their distances total exactly 63.4 miles. Every sample summary derives its total from this same local dataset. Sample rows have no receipt/upload actions and are different Swift types from actual trips and API payloads.

The switch is **session-only**, off on a fresh launch. After force-quitting/reopening, turn it on again. It does not persist sample records or overwrite actual preferences. Actual account restoration and existing read refreshes may run normally at app launch; displaying and switching the samples requires no backend request. The sample views suppress their normal screen refreshes while enabled. Developer Mode and Test Calculation remain available.

## Install on Htoo’s iPhone

A signed build was successfully produced with the project's existing signing team and bundle ID `com.hackpsu.driveandsave`. The connected physical device was identified as **Htoo’s iPhone (iPhone 17)**. No installation or launch was performed on that phone during this task.

Recommended Xcode path:

1. Keep the phone connected and unlocked. **Do not delete the existing Drive Save app**, reset its account, or change the bundle identifier/signing team.
2. In this checkout, select `codex/presentation-mode` and open `/Users/htoolinhtet/Developer/drive-save/ios/DriveAndSave.xcodeproj` in Xcode.
3. Select scheme **DriveAndSave** and destination **Htoo’s iPhone** (the physical device, not a simulator).
4. Use **Product → Run** (⌘R). This installs an update in place with the existing app identity. If Xcode requests phone trust/unlock or Developer Mode, complete its on-device prompts. Do not use the UITest account arguments on the real app.
5. Confirm the normal Profile still identifies the existing account and the actual Test League is intact. Then enable Presentation Mode.

Alternatively, install the already-built signed artifact from this Mac without rebuilding:

```sh
xcrun devicectl device install app --device "Htoo’s iPhone" \
  /tmp/DriveSavePresentationSigned/Build/Products/Debug-iphoneos/DriveAndSave.app
xcrun devicectl device process launch --device "Htoo’s iPhone" \
  com.hackpsu.driveandsave
```

These two commands are provided for you to run; they were not executed. The temporary build artifact may disappear after system cleanup. To regenerate it:

```sh
cd /Users/htoolinhtet/Developer/drive-save/ios
xcodebuild -project DriveAndSave.xcodeproj -scheme DriveAndSave \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/DriveSavePresentationSigned build
```

## Suggested presentation sequence

1. Open **Leagues**, briefly show the actual Test League, then turn on **Presentation Mode**. No account switch or Developer Mode is needed.
2. Show the **Sample League**: Htoo highlighted, #1 at $1.42; lower weekly estimated avoidable cost ranks first. Scroll to show all six players.
3. Tap **Home**: show $1.42, Audi A4, eight sample trips, 63.4 miles, #1 of 6, and the informational 18% improvement.
4. Open **Profile** for the matching sample summary, then **History** for eight explicitly fictional trips. These are illustrative results, not recorded trips or financial receipts.
5. You can turn off Wi-Fi/cellular for this sample portion; no sample data needs a server. No request to toggle device networking was performed during verification.
6. Turn **Presentation Mode off** to reveal actual data again. Normal league invites, refresh, standings, Home totals and incomplete real recordings remain available.
7. For the separate genuine backend calculation video, restore connectivity, use **Profile → Enable developer tools → Developer tools → Test Calculation**. This existing workflow and its separate test-account handling are unchanged. The sample Audi display does not select or reprice a real vehicle; use the vehicle already selected for Test Calculation.

Start Drive is shown only in the actual Home view. Recording, calibration, sensor services and trip upload behavior themselves are unchanged.

## Verification and limits

Passed:

- Signed and unsigned generic iPhone builds. Signature verification passed with macOS trust services available.
- All 328 existing portable Swift regression checks, including financial Test Calculation, recording contracts, calibration-related models, telemetry, accounts, receipts and uploads.
- 20 new presentation checks: exact costs/order, eight unique sample rows, exact cents and miles, shared totals, presenter rank, safe default, repeated switching with zero API requests, unchanged credentials/identity/vehicle/progress/membership/invite, byte-identical account/upload/receipt-cache and history files, and unchanged actual totals. These use isolated fixture accounts and intercepted requests, not the real Htoo account.
- A negative compilation test proves `PresentationData.SampleTrip` cannot be passed to `TripUploadBuilder.payload(for:)`.
- Four existing simulator UI regressions passed: Home, actual League, original developer showcase, and onboarding/account restoration.
- The new simulator flow passed: accessible switch with Developer Mode off, all six costs, consistent Home/Profile/History, eight sample trips, preserved Developer Mode/Test Calculation access, and restoration of the actual league/invite/Home/identity.
- Home and six-player league screenshots visually inspected in the existing black/lime design.
- Diff checked: no changes to backend, database, financial model, sensor/GPS/calibration, API clients, upload builder, account view models, or project signing settings.

Initial checks caught a ten-cent fixture discrepancy and two UI selectors that did not match SwiftUI's accessibility element structure. They were corrected; the final focused UI test and full Swift runner pass. Initial sandboxed Xcode/signature attempts lacked compiler-plugin/trust-service access; reruns with normal tool access passed. No production traffic, data seeding, deployment or main merge was performed.

Unverified: physical-phone installation/launch, real Keychain restoration after that install, an actual radio-off run, and physical-device layout/interaction. Simulator checks demonstrate offline sample operation; the existing on-device account was deliberately not accessed. No new claim of on-road or financial-model accuracy is made.

Local evidence:

- `/tmp/drivesave-presentation-final-swift.log`
- `/tmp/drivesave-presentation-ui.log` (four existing UI passes plus the earlier selector failure)
- `/tmp/drivesave-presentation-final-ui.log` (final presentation UI pass)
- `/tmp/drivesave-presentation-device.log`
- `/tmp/drivesave-presentation-signed.log`
- `/tmp/DriveSavePresentationSimulator/Logs/Test/Test-DriveAndSave-2026.10.25_09-30-08--0400.xcresult`

Run the offline Swift checks with `bash Tests/run_recording_regressions.sh`. The presentation compile-time boundary check is included. For the focused simulator UI test, use Xcode's `PresentationModeTests`; its helper creates a unique offline test account and never uses production.
