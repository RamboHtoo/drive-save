# Consumer interface cleanup

The existing SwiftUI screens, black/lime tokens, navigation, backend clients, authentication, persistence, and financial models remain in place. This change is limited to `/ios` and layers on top of the existing in-progress integration work.

## Everyday flow

- Sign up with a driver name. Offline onboarding and demo-account recovery are collapsed under Developer options.
- Profile → My Vehicle → Choose/Change vehicle → Brand → Model → Year → Save. The summary contains the car, EPA MPG, fuel, and basic specifications. Unsupported cars retain their unavailable-estimate warning.
- Home contains the financial/progress metric, Start Drive, and parked-use reminder. The telemetry illustration was removed; there is no league promotion or recent-trip list. Online progress still comes only from the backend, with no sample fallback.
- Recording defaults to Driving. Mount confirmation, calibration, location permission, foreground-only recording limits, incomplete measurement warnings, interruptions, and parked stopping remain available.
- History shows date/time, distance, estimated amount or Pending, and opens the receipt. Normal online history excludes the mock snapshot and synthetic recordings; local storage is unchanged. Offline sample rows remain labeled Demo.
- Receipts show estimated fuel impact, the server-reported pricing vehicle (or an honest unavailable state), returned costs, distance/time, and a short expandable explanation. No current vehicle is retroactively claimed as a recording's vehicle. Unpriced recordings keep a manual estimate request when eligible.
- Leagues show name, member count, invitations, and individual rankings/readiness. Fictional example standings were removed. Create/join remain available; after joining they sit under Manage league. Full invitation sharing still includes the unchanged ID/code required by the API; manual invite entry is collapsed.

## Hidden or relocated

Profile → Developer Mode → Enable developer tools → Developer tools provides:

- Test Calculation → Test Calculation, using the existing saved vehicle and isolated demo identity.
- Recording tests; enabling Developer Mode reveals Walking Test, Demo Drive, and live sensor diagnostics.
- History & receipt diagnostics: timeline, IDs, sensor/calibration details, local demo inputs, raw upload eligibility, server model/assumptions/notes, and JSON export for eligible recordings.
- API URL and connection switching, account UUID/reset, EPA example/import/editor/upload/fetch, and detailed backend notices/errors.

The sample History chart was removed. Walking Test inclusion is visible only with Developer Mode enabled. Normal screens show concise actionable failure messages; detailed server messages remain in Developer tools. Raw EPA fields and coefficients are preserved in the stored/full API objects and diagnostics, not exposed in normal vehicle or receipt summaries.

Developer Mode defaults off and is an explicit device preference. It does not alter account credentials, API contracts, demo isolation, recording algorithms, eligibility, or financial calculations.

## Verification

Portable regression suites: 34 model/GPS/persistence, 45 backend/auth/contract, 30 vehicle catalog, and 50 isolated calculation checks passed (159 total). Simulator builds passed on iPhone 17 Pro Max and iPhone 17e (iOS 26.4). All 13 distinct offline UI tests passed across the main suite and focused reruns, covering Home, accessibility text, invitations/rankings, onboarding/Keychain persistence/reset, receipts, four recording flows, navigation layout, vehicle selection/restore/account isolation, and Walking Test persistence/exclusion.

The initial suite exposed a gap in the compact History row’s tap target; the whole row is now tappable and the rebuilt receipt test passed. The initial denied-location test encountered an already-granted simulator permission; after setting the required denied state, that flow passed. The final targeted build/test reported TEST SUCCEEDED. Live account-creation/calculation tests and the route-dependent GPS test were excluded from these offline runs.

Visually reviewed [Home](DesignPreviews/consumer-home.png), the vehicle picker capture, and [Receipt](DesignPreviews/consumer-receipt.png). `git diff --check` passed.

Physical driving accuracy, background recording, and real fuel savings are not claimed by these checks. Live network/account-creation suites and the route-dependent GPS UI check remain opt-in.

## Local recording cleanup and primary developer demo

Test Calculation remains the first developer demo. The obsolete Contract Demo Replay panel/button was removed from the UI because the old fixture is no longer accepted for scoring (`missing_boundary_speed`). `BackendViewModel.replayContractFixture`, the stored replay state, fixtures, and API-level tests remain available internally. No fixture/GPS evidence or financial calculation was changed.

History marks zero, negative, nonfinite, or explicitly unavailable recording distance as **Incomplete recording**. It does not invent mileage or replace a missing estimate with a price. The row still opens its receipt for inspection. A small known distance displays `<0.01 mi` rather than rounding to a false zero. Existing returned server receipts retain their actual amounts.

Open a locally saved recording, then choose **Delete local recording** → **Delete from this iPhone**. Cancel leaves it saved. Confirmation removes only that ID from the atomic local trip store and visible history. Snapshot-only rows cannot be deleted. Deleting directly after recording also updates the saved screen and removes its stale Open receipt action. This operation has no authenticated backend reference, does not clear receipt/upload retry caches, sends no API request, and leaves server trips, receipts, credentials, vehicles, and league standings unchanged. Failed persistence retains the visible recording and offers another attempt.

The local-history regression suite covers legacy/zero/unavailable distance, preserved existing estimates, local-only eligibility, exact persistence, retained neighboring recordings, relaunch, repeated deletion, failed persistence, and zero network requests. Run it with:

```sh
swiftc -module-cache-path /tmp/drive-save-module-cache \
  DriveAndSave/Models/{DrivingModels,RecordingModels,BackendModels,TripExportPayload}.swift \
  DriveAndSave/Services/{TripStore,APIClient}.swift DriveAndSave/MockData/DemoData.swift \
  DriveAndSave/ViewModels/AppViewModel.swift Tests/TripHistoryTests.swift \
  -o /tmp/drivesave-history-tests
/tmp/drivesave-history-tests
```

Follow-up verification: all 180 portable checks passed (the existing 159 plus 21 local-history checks). The updated developer tools flow verifies Test Calculation is available and the obsolete replay control is absent. The recording UI suite passed all five tests, including incomplete-recording inspection from History, Cancel, confirmed local deletion, relaunch persistence, and correct post-save UI after deletion. Existing Home, accessibility, onboarding/authentication, receipts, leagues, vehicle selection, navigation, and Walking Test checks were also rerun.

An initial deletion UI assertion assumed there were no older recordings with the same title. The test now compares against the pre-existing count and verifies that only the newly created recording disappears; it leaves older simulator recordings intact.

Final result: 14 distinct offline UI tests passed across the full run and corrected focused reruns; the final recording suite (5/5) and final receipt build/test reported TEST SUCCEEDED. Live API/account-creation and route-dependent GPS tests were excluded. `git diff --check` passed.
