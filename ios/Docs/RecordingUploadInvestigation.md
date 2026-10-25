# Physical recording upload investigation — October 25, 2026

Only `/ios` was modified. The connected development iPhone was inspected **read-only** with `devicectl`. Only Drive Save's `Library/Application Support/DriveSave/trips.json` and `backend-state.json` were copied into temporary files. No app was installed on the phone, no Keychain data was read, no production API or database was queried or changed, and no physical trip was submitted. Raw recordings and coordinates are not committed to the repository.

## Actual physical recordings

Times below are America/New_York (EDT). IDs are abbreviated local recording IDs. The native production `TripUploadBuilder` was run locally on the saved records without changing their readings or completeness flags.

| Local ID | Started | GPS speed samples / valid | Definitive local sensor blocker | Additional evidence |
| --- | --- | --- | --- | --- |
| `04EC9FEC` | Oct 25, 07:13:53 | 46 / 40 | `event_recording_incomplete` | Mount-angle change and foreground interruption; calibration invalid at end. Valid GPS edge gaps 1.994 s / 0.748 s, largest valid-speed gap about 3 s. 433 actual motion samples. |
| `FB599B63` | Oct 25, 07:11:33 | 93 / 90 | `gps_boundary_gap_over_three_seconds` | First valid GPS speed at **4.493 s**, outside the 3 s limit; trailing gap 0.622 s, largest valid-speed gap 1 s. Calibration valid, no recorded interruptions, but `events_complete=false` and ineligible monitoring overlaps the GPS window around 41.504–42.306 s. 939 motion samples. |
| `6A8F080A` | Oct 25, 07:10:54 | 10 / 7 | `event_recording_incomplete` | Detector unavailable at Start; no recorded motion samples; calibration invalid. |
| `499A551A` | Oct 25, 07:06:43 | 38 / 0 | `insufficient_valid_speed` | No usable distance; all monitoring ineligible; calibration valid alone does not establish completeness. |
| `3B6DCB9C` | Oct 25, 03:14:04 | 16 / 0 | `insufficient_valid_speed` | Zero distance; mount-angle failure; calibration invalid. |
| `2AF9206B` | Oct 25, 02:50:48 | 9 / 0 | `insufficient_valid_speed` | Older detector 0.2.0; zero distance, detector pause, mount change and foreground interruption. |
| `5A6A2924` | Oct 25, 02:36:14 | 28 / 0 | `insufficient_valid_speed` | The 67.912 s / 0.0392 mi capture; position distance exists, but no valid speed+accuracy observations; older detector pause and real GPS-gap interruption persisted. |
| `56EBC5F7` | Oct 24, 17:15:57 | No speed archive | Walking Test excluded from driving uploads | 128.447 s / 0.05435 mi, no starting account/vehicle metadata; GPS/foreground interruptions. |
| `52AA1444` | Oct 24, 16:30:06 | No speed archive | Legacy simulated recording lacks required upload metadata | No recording-start client ID, speed archive or detector completeness metadata. |

The seven device driving recordings have confirmed, supported starting vehicles. Their sensor gates fail independently of any additional current-account check. Current Keychain ownership was deliberately not inspected; the app continues to enforce it before upload.

The phone's cache contains two unrelated upload entries, **none matching any of these nine recordings**, and no new transport traces (it predates this diagnostic update). Therefore no submission or server acceptance is recorded locally for these captures. They are blocked by the current native preflight, consistent with their absence from Tiger Cloud. Missing old transport logs are not proof about every historical network packet; the new persistent trace removes that ambiguity for future attempts.

The old 0.04 mi / 1:07 warning can now be narrowed down: real position distance was saved, but valid scoring-speed observations were absent and the older recording explicitly saved a GPS-gap interruption. It must not be turned into a driving receipt by filling missing speeds or prices.

The two latest recordings were also serialized with the native production builder and evaluated **locally**, read-only, through backend `5094a01`'s actual `TripCreate`, adapter and vehicle-fuel-v2 model. The probe mirrors the server's existing DEMO_ONLY flag handling in memory; original JSON provenance, readings and completeness remain unchanged. The mount/foreground capture was refused with `valid_time_coverage_below_95_percent`; the no-mount capture was refused with `gps_boundary_gap_over_three_seconds`. Both returned no financial/fuel result. These are evaluations of actual physical saved evidence, distinct from the controlled timing/fixture regressions; neither was uploaded. This also demonstrates that simply bypassing the iOS gate would not make these captures score.

## Stop & Save → receipt path

1. `TripRecordingView.finish()` calls `TripRecordingService.finish()`. This freezes Stop time, builds the local `Trip` and retains starting account, full vehicle, original client UUID, raw readings, coverage and interruptions.
2. `AppViewModel.save()` writes `TripStore`'s local `trips.json` atomically and updates local History. **There is no automatic upload on Save or History open.**
3. The receipt offers **Get estimate** only after local eligibility checks pass. Ineligible trips remain local and inspectable. The updated UI explicitly explains this manual upload step.
4. `BackendViewModel.prepareUpload()` is now shared by displayed eligibility and the actual upload. It checks starting account/server/confirmed supported vehicle, GPS-window and detector metadata, then payload/event validity. Previously the upload and UI checked payload/scoring failures in different orders; they now agree on the first blocking reason.
5. `submit()` freezes the existing UUID, payload and starting vehicle before network access. A vehicle PUT and account recheck occur before POST. New transport evidence records **POST attempted only immediately before URLSession handles POST /trips**, after PUT/auth setup. A failed PUT is not a trip upload.
6. A decoded `APITripCreated` is saved before receipt GET. Retries reuse the saved server ID and do not create another POST. Only `trip_not_scored` is called **Uploaded but not scored**; a lost receipt connection is **Uploaded · receipt pending**. A successful receipt is **Successfully scored**. A POST with no response/usable acceptance is **Upload not confirmed**.
7. All transport history is scoped to account, server and client UUID. Other accounts cannot read a driver's cached upload result. Offline mock receipts never claim a backend upload. Old cache entries decode without invented attempt timestamps.

## iOS bug found and fixed

The live detector previously cached only the newest GPS observation. A pending Core Motion callback can carry an observation timestamp before that GPS observation. `freshSpeed(newestGPS, at: motionTime)` then rejects the GPS as being in the future, even if an earlier actual GPS observation is still fresh and valid. That can produce spurious ineligible monitoring without a mount warning.

`DetectorGPSHistory` now retains a short bounded history of actual received observations and chooses the most recent at/before the actual motion observation timestamp. It retains the same 3 s freshness and speed/accuracy checks, never falls back past an invalid newest-at-time observation, and never invents, shifts or interpolates readings. Raw recording arrays, sensor sampling frequencies, event thresholds and telemetry smoothing are unchanged. New monitoring runs also persist their actual eligibility reason. New sessions use detector version `ios-0.3.1` to distinguish the corrected GPS lookup; saved 0.3.0/older recordings retain their original versions.

The regression reproduces the old failure with GPS timestamps 0.5 s and 1.5 s and a delayed motion observation at 1.4 s: the newest-only check fails, while the real 0.5 s observation legitimately supports monitoring. This is controlled timing evidence, not synthetic financial or physical-drive evidence.

The physical no-warning recording contains an ineligible run despite continuous valid saved GPS around that time, consistent with this bug, but callback delivery times were not archived, so its exact historical cause cannot be proven. **Its independent 4.493 s GPS startup failure remains definitive.** The mount-warning recording has genuine failures that this patch must not erase. No old `events_complete` or recorded event is recomputed or upgraded.

A first GPS observation delivered after earlier motion callbacks may still leave genuinely unmonitored startup evidence inside its measured GPS interval. This patch only recovers previously received past GPS evidence; it does not retrospectively claim that classification ran before GPS was available. Such records remain incomplete. Any broader buffering/replay or different scoring-window contract needs a separately agreed implementation, not a completeness override.

## Developer-only diagnostics

Enable Profile → Developer Mode. Open a receipt → **Recording diagnostics**, or Profile → Developer tools → History & receipt diagnostics. The summary can be shared as text and includes:

- Local-only / POST attempted / server accepted, with explicit offline/legacy-unknown variants.
- Exact first preflight failure, request stage, HTTP status/code/message, actual POST count and timestamp, server trip ID and scoring refusal.
- Saved GPS sample and valid-speed counts, first/last edge gaps, largest valid-speed gap and observations outside the original interval.
- Saved motion count, finite calibrated axes count, largest observed motion gap, eligible/ineligible coverage evidence, window overlap and interruptions.
- Calibration state, `events_complete` and the saved `detector_version`.

These are read-only projections. GPS position coverage is distinguished from valid scoring speed coverage. Unknown legacy data remains unknown. Normal History/receipt screens now distinguish local ineligibility from upload/receipt outcomes; technical detail stays under Developer Mode. Known-invalid trips are never submitted just to populate the database.

## Verification and remaining work

Verified results:

- Final native simulator app and UI test build: **TEST BUILD SUCCEEDED**, `/tmp/drivesave-upload-diagnostics-final-build.log`.
- **326 portable Swift checks passed**: 34 model/storage, 51 backend/auth, 30 vehicle catalog, 50 Test Calculation, 21 local history, 27 league/view-model/transport, 25 diagnostic/callback-history, 22 recording-contract, 34 v2 GPS/motion and 32 live telemetry. Final log: `/tmp/drivesave-upload-diagnostics-final-verified.log`; suite logs: `/tmp/drivesave-recording-tests.69etbe`.
- **10/10 controlled Swift → Python compatibility cases passed** using the existing synthetic fixture readings, the actual serializer and fetched backend model. These cover positive compatibility and honest refusals; no expected monetary values are invented.
- The full offline native suite passed **17/17 UI tests, zero failures**. Log: `/tmp/drivesave-upload-diagnostics-ui.log`; result: `/tmp/DriveSaveUploadDiagnostics/Logs/Test/Test-DriveAndSave-2026.10.25_07-34-13--0400.xcresult`.
- **2/2 final focused UI tests passed, zero failures**, covering Developer Mode visibility (including hiding the summary in ordinary use) and denied-location History. Log: `/tmp/drivesave-upload-diagnostics-final-ui.log`; result: `/tmp/DriveSaveUploadDiagnosticsFinal/Logs/Test/Test-DriveAndSave-2026.10.25_07-45-20--0400.xcresult`.
- **Nine actual saved recordings** decoded by native models and inspected read-only; the seven physical driving captures all fail their actual sensor preflight. **Two actual recent native-serialized payloads** were also refused by the local backend validator/model without financial results. Logs: `/tmp/drivesave-physical-preflight-results.log`, `/tmp/drivesave-physical-python-mount.log`, `/tmp/drivesave-physical-python-startup.log`.
- `git diff --check` passes; all repository changes are under `/ios`.

 Tests are offline; live authentication, live calculation and GPS-route suites are excluded. Physical exports were inspected and passed through native preflight locally, never uploaded. The connected phone remains on its existing app build.

A new mounted, calibrated physical car trip is still required after installing this patch through the normal development workflow. Confirm the deployed backend's v2 contract and shared observed-GPS-window completeness semantics, then verify fresh GPS from Start, actual monitoring continuity, parked Stop and explicit Get estimate. This investigation does not claim a successful physical trip-to-financial-receipt pipeline.
