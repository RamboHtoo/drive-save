# Final iOS integration report

This is the historical v2 integration baseline. See [Physical recording upload investigation](RecordingUploadInvestigation.md) for the subsequent read-only iPhone evidence, detector 0.3.1 callback fix, and current diagnostics/test results.

Work is on `ios`, restricted to `/ios`. No deployment, backend/analytics edits, financial equation changes or production mutations were performed.

## Files changed

Integration changes:

| Files under `/ios` | Purpose |
| --- | --- |
| `DriveAndSave/Models/RecordingModels.swift` | Observed GPS-window preflight, actual eligible motion runs, saved GPS quality, detector version 0.3.0, no distance bridging over gaps >3 seconds |
| `DriveAndSave/Services/TripRecordingService.swift` | Real recording coverage, fresh low-speed monitoring, recoverable GPS callback errors, saved quality evidence |
| `DriveAndSave/Services/TripUploadBuilder.swift` | New boundary policy; backend final quality checks; accurate event speed evidence |
| `DriveAndSave/Models/BackendModels.swift` | Optional v2 receipt metadata, precise private-league error predicate, source-conflict explanation |
| `DriveAndSave/ViewModels/BackendViewModel.swift` | Account-scoped stale private league removal; safe consumer error; injectable offline test storage/client |
| `DriveAndSave/Views/APISettingsView.swift` | Show actionable source-conflict explanation |
| `DriveAndSave/Components/ReceiptDocument.swift` | Server coverage label, scored distance and notes |
| `DriveAndSave/Views/TripReceiptView.swift` | GPS-window and actual gap evidence in Developer Mode |
| `Tests/V2IntegrationTests.swift` | 34 GPS/motion/quality edge cases |
| `Tests/LeagueIntegrationTests.swift` | 15 actual view-model league/account/vehicle/retry cases |
| `Tests/RecordingContractTests.swift` | New policy and ten production-serializer fixture outputs |
| `Tests/check_recording_compatibility.py` | Latest Python adapter/model positive and refusal cases |
| `Tests/run_recording_regressions.sh` | New suites and optional Python probe |
| `Docs/GenuineRecordingContract.md`, `README.md`, this report | Current contract, explicit teammate correction and limits |

Existing uncommitted telemetry work was retained: `DriveAndSave/Models/LiveTelemetry.swift`, `DriveAndSave/Components/LiveTelemetryView.swift`, `DriveAndSave/Views/TripRecordingView.swift`, `Tests/LiveTelemetryTests.swift`, `DriveAndSaveUITests/RecordingFlowTests.swift`, `Docs/LiveTelemetry.md` and `Docs/DesignPreviews/live-telemetry.png`. Telemetry integration in `TripRecordingService.swift` and the regression runner was also retained. Its display smoothing, sampling, signed values, accessibility and design were preserved.

## Issues fixed and completeness

The obsolete one-microsecond GPS endpoint guard is removed. Original Start/Stop and sensor timestamps are preserved. Valid speed observations must be 0–53.6448 m/s with accuracy 0–2 m/s, lie inside the session, number at least two distinct times, and reach within three seconds of both buttons. Backend still owns detailed coverage, gap, physics, distance and event gates.

`events_complete` requires actual motion observations bracketing the first-to-last valid GPS interval, no unexplained motion gap >1 second, finite calibrated axes, fresh valid GPS during monitoring, no real interruption/calibration failure, and consistent session/event version. A verified low-speed stop suppresses classification without pretending sensors were absent; missing/stale GPS remains unknown. Old records gain no inferred metadata. Version becomes `ios-0.3.0`; thresholds and financial equations are unchanged.

Private league GET403 `forbidden` clears only that account's stale league ID and standings. Unrelated errors keep league state. Credentials remain intact. 409 `mixed_trip_sources` explains separate recorded/demo accounts. Test Calculation stays isolated. Owner/vehicle snapshots and stable retry IDs remain enforced and tested.

## Partial warning diagnosis

The previous permanent error/timeout latch could overreport incomplete GPS after recovery. New state derives from actual reliable measurement times, records startup/trailing/interior gaps, distinguishes startup waiting from usable distance, and never integrates distance across gaps >3 seconds. Speed validity remains separate from position validity. Real missing coverage remains visible; walking remains ineligible for driving uploads.

No raw export accompanied the reported 0.04 mi / 1:07 test, so its exact cause cannot be reconstructed. The new diagnostics support the next physical test without fabricating historical mileage or receipts.

## Required backend/analytics correction

The owner approved observed GPS-window completeness. The latest shared `docs/gps-scoring-window.md` rule 8 still says `events_complete` spans the original session. Replace it with the observed-window semantics above and coordinate deployment. The current executable model can consume the JSON and score that interval, but shared documentation is not yet consistent. No claim is made about the deployed version.

Per-trip atomic vehicle binding and experimental-versus-synthetic receipt/progress provenance remain existing backend concerns. See `GenuineRecordingContract.md` for the precise handoff.

## Verification

- Final native simulator build: **BUILD SUCCEEDED**, `/tmp/drivesave-v2-final-build.log`.
- Final complete portable run: **289 checks passed** — 34 model/storage, 51 backend/auth, 30 catalog, 50 Test Calculation, 21 local history, 15 league/view-model, 22 recording contract, 34 v2 GPS/motion and 32 live telemetry. Log: `/tmp/drivesave-v2-final-regressions.log`; suite logs: `/tmp/drivesave-recording-tests.IxWVd2`.
- **10/10 Swift → Python compatibility cases passed**, using backend `5094a01` request validator, cost adapter and actual fuel model (matching analytics `3545885`). Five controlled fixtures scored, including asynchronous and exactly-three-second edges and genuine-provenance serialization. Five failed with their expected reason and no financial/fuel result. No expected dollar values were fabricated. These are synthetic fixture tests, not physical evidence.
- **16/16 offline UI tests passed, 0 failures**; `/tmp/drivesave-v2-xcode.log`. Result bundle: `/tmp/DriveSaveTelemetryBuild/Logs/Test/Test-DriveAndSave-2026.10.25_02-58-05--0400.xcresult`. A subsequent final native build includes the finite calibrated-axis validity guard; physical sensor validation remains pending.
- Source scope and whitespace: `git diff --check`; all modified/untracked repository files are under `/ios`.

The exact portable/Python and simulator commands are in `GenuineRecordingContract.md`. Live authentication/calculation and Core Location route suites were excluded from the offline simulator run; no production calls were made.

## Offline UI cases

The offline suite includes:

- `BackendFlowTests.testOfflineVehicleToolsAndLeague`
- `HomeDesignTests.testHomeProvenanceRecordingAndProfileRemainAccessible`
- `LargeTypeDesignTests.testAccessibilityTypeCanReachHomeFooterAboveNavigation`
- `LeagueDesignTests.testChampionshipRowsInviteAndSecondaryNavigation`
- `OnboardingTests.testFirstLaunchPersistenceLeagueAndExplicitReset`
- `ReceiptDesignTests.testDemoReceiptHasNoInventedTimelineAndNoPrimaryRail`
- `RecordingFlowTests.testDeletingFreshRecordingUpdatesSaveScreen`
- `RecordingFlowTests.testDeniedPermissionCanFinishWithoutDistance`
- `RecordingFlowTests.testLeavingForegroundEndsRecording`
- `RecordingFlowTests.testRecordingHasFocusedNavigationAndStillEndsOnInterruption`
- `RecordingFlowTests.testRecordingKeepsStartingVehicleAfterProfileChangeAndRelaunch`
- `RecordingFlowTests.testSimulatedRecordingPersistsAndExistingScreensOpen`
- `RecordingFlowTests.testTelemetryAtAccessibilityTextSizeKeepsStopReachable`
- `ScrollLayoutTests.testLeaguesFooterAndStatusScrollAboveNativeTabBar`
- `VehiclePickerTests.testSearchSaveRestoreUnsupportedVehicleAndAccountIsolation`
- `WalkingFlowTests.testWalkingDeniedSavesReloadsAndExcludesDrivingAndCrew`

## Physical verification still required

Use a parked, securely mounted and calibrated iPhone, then a real car trip with no screen interaction while driving. Verify genuine speed accuracy/cadence, CM continuity, startup/tail coverage, normal red lights, GPS loss, distance agreement, interruptions, owner and selected car. Confirm the deployed backend supports v2 and the agreed completeness interpretation, then inspect a real receipt and league outcome.

**Genuine recordings are locally eligible when their actual evidence qualifies; full physical driving-to-financial-receipt success remains unverified.** No physical export was available and no live upload was attempted.
