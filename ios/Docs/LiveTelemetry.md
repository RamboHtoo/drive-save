# Live trip telemetry

The existing recording screen now shows GPS speed in MPH, signed forward/lateral acceleration in g, cumulative trip distance, and elapsed time. It keeps the black/lime design and the parked-start/parked-stop guidance. Values have no animation, warning colors, sounds, speed targets, or gauges. The panel explicitly says it is for parked review and is not a speedometer.

## Data and frames

`TripRecordingService.liveTelemetryInput` is a read-only projection of the existing sensor outputs. It caches the latest Core Location speed separately for display, including invalid readings so an earlier good reading does not conceal a newer invalid one. Permission denial and GPS failures clear that cache. It does not change GPS acceptance, stored speed samples, recorded motion, the detector filter, thresholds, sampling rates, trip timing, vehicle/account binding, uploads, or financial calculations.

Acceleration comes from `CMDeviceMotion.userAcceleration`, which excludes gravity and is already expressed in g. When mounting is confirmed and calibration remains valid, that vector is projected onto the existing calibrated forward/lateral basis. It is **not** derived from GPS speed, acceleration including gravity, absolute magnitudes, or the detector's filtered values. When calibration/mount validation is unavailable, fresh phone y/x values are labeled **Device Y / Device X**. If there are no usable motion samples, both values are `—`. An orientation-invalidated mount cannot continue presenting its old vehicle frame.

Uncalibrated GPS-only recording continues to work as before. This feature does not start extra motion capture just to populate the display. If the existing service is not collecting motion, acceleration remains unavailable.

Demo Drive remains explicitly synthetic. Its existing motion fixture can populate simulated acceleration, but its GPS fixture has no observed speed accuracy, so GPS speed stays unavailable. Software-simulated Core Location data is also identified as simulated. No confidence measurements are invented.

## Presentation policy

`LiveTelemetryDisplay` is an independent, non-persisted presentation model:

- Refresh at **2 Hz** using a view task that cancels when the panel disappears. Sensor sampling frequencies and recording timers are unchanged. Refresh reads the latest samples in constant time; it never scans recorded histories.
- GPS speed expires after **3 seconds**. Motion expires after **1 second**. Future-dated, non-finite, missing and invalid values show `—`.
- Speed display requires nonnegative finite GPS speed, speed accuracy of 0–2 m/s, and horizontal accuracy of 0–35 m. These are display quality checks; they do not modify recording or scoring eligibility.
- Time-based exponential display smoothing uses a 0.6-second time constant. Re-reading the same observation does not filter it again. Stale/invalid data clears the filter. Observation gaps and frame/provenance changes restart it.
- Vehicle and phone axes are never blended across a frame change. Values retain their positive/negative signs, including explicit `+` signs, and use three decimal places in g.
- Cumulative distance is retained through GPS outages and after capture ends; it is a trip total, not a live sensor reading. Unknown distance shows `—`; a known distance below 0.01 mi shows `<0.01 mi`. Existing partial-distance warnings remain available.
- Ending capture clears live speed/acceleration. It preserves elapsed time and recorded distance.

## Accessibility

Each metric is an independent VoiceOver element with a label and a value, including spoken positive/negative acceleration direction and units. The panel does not post accessibility announcements or create a live region. It has no changing-value animation. Accessibility text sizes use one column instead of two, keeping metrics readable and Stop reachable by scrolling while parked. Regular rows keep all five metrics in the layout, and starting capture returns the viewport to the top without animation.

Developer diagnostics now sit below Stop, leaving the telemetry and parked-stop control ahead of technical details. The existing sensor diagnostics and candidate-event tools remain available.

## Tests

Run from `/ios`:

```sh
bash Tests/run_recording_regressions.sh
```

This includes the original 208 checks plus 32 telemetry checks. The telemetry checks cover conversion, gravity-corrected signed inputs, spoken/visible signs, stale and future timestamps, validity, repeated samples, display-only smoothing, frame changes, outage recovery, missing/zero/invalid totals and stopped recording. Existing upload, vehicle/account ownership, Test Calculation, receipt and local-history tests continue to run.

The offline simulator suite checks all five telemetry metrics, accessibility labels/values, signed g, synthetic labeling, unavailable data, large accessibility text, Stop, interruption handling, persistence, unchanged starting-vehicle binding, deletion and the existing consumer flows. Live/production and route-dependent tests are excluded; no production data is altered. Physical iPhone motion and real GPS performance require device validation.

## Verification results

- Native simulator build passed.
- All **240 portable checks** passed, including 32 new telemetry checks and the existing 208 recording/upload/authentication/catalog/financial/demo/history checks.
- The full offline UI run passed 14 of 16 tests. The new large-text check exposed offscreen lazy cells, and the Walking Test needed to scroll to the developer event count after it moved below Stop. The panel now uses regular rows and returns to the top when recording begins; the tests follow reading order and scroll to diagnostics.
- The final focused run passed **3/3**: telemetry values/signs/accessibility, largest accessibility text with Stop, and Walking Test persistence/exclusion. Across the full and corrected focused runs, all **16 distinct offline UI tests** passed. The final run reported **TEST SUCCEEDED**.
- The final screen capture was visually inspected; all five metrics and Stop remain visible at standard text size. [Preview (explicitly synthetic data)](DesignPreviews/live-telemetry.png).
- `git diff --check` passed. All changes are under `/ios`; no production tests, backend/analytics changes or deployment occurred.

Logs: `/tmp/drivesave-telemetry-regressions.log`, `/tmp/drivesave-telemetry-xcode.log`, `/tmp/drivesave-telemetry-final-ui.log`. Native result bundles: `/tmp/DriveSaveTelemetryBuild/Logs/Test/`.
