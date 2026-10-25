# HackPSU demo readiness — 2026-10-25

## Changes

Online Home now requests the signed-in driver's `GET /users/{user_id}/progress`. The headline shows the server's signed weekly `est_savings_usd`, only when the server reports a completed baseline and a weekly improvement result. No scored trips, a baseline still in progress, and an unavailable weekly estimate have separate states; they never substitute offline sample dollars. Negative savings remain negative. Pull to refresh, reopening Home, resuming the app, and trip submission refresh progress. Account, API mode, and vehicle changes invalidate the displayed progress; outdated requests cannot overwrite a newer account/mode.

Offline Home keeps its bundled illustrative costs and explicitly says Offline Demo. Online telemetry shows only locally measured driving traces; simulated traces remain available in Offline Demo and their own receipts.

Server receipts display the pricing vehicle whenever returned, exact server dollars to up to four decimal places, event costs, and the high-speed portion. Model inputs, sources, and notes expand under **How it’s calculated**. The duplicate local assumptions section disappears once a server receipt is available. Placeholder pricing, synthetic/demo provenance, and the server's accuracy warning remain visible. A missing/invalid receipt or `trip_not_scored` stays an error, without a fabricated amount.

Leagues refresh after successful creation/joining and on pull to refresh. Individual standings use the server's readiness states (`collecting_baseline`, `zero_baseline`, `no_weekly_trips`, `ready`). Unranked drivers have no savings claim. Experimental online demo leagues are labeled as such, rather than labeling actual remote members as simulated drivers.

No sensor code, scoring rules, calculations, or API contracts changed. All changes are inside `/ios`.

## Source of truth

Inspected the backend branch's [API contract](https://github.com/RamboHtoo/drive-save/blob/backend/docs/api.md), user/trip/leaderboard models, progress repository implementation, and user routes. In particular, `/leaderboard` has no query parameters; progress is self-only; receipt amounts are not nullable in the current contract. Trips and leagues are currently experimental demo data on the server. The app does not infer validated accuracy from deployment availability.

The progress `trips_counted` field counts accepted trips in the current repository implementation, so it is not displayed as a count of scored trips. Baseline readiness and weekly availability come from the explicit response fields. New zero-trip accounts show “No scored trips yet.”

## Verification

- Signed Xcode builds succeeded. All 16 distinct UI tests passed across iPhone 17e (390 × 844) and iPhone 17 Pro Max (440 × 956), with 18 successful executions including repeated layout checks. The small-screen full regression suite passed all 13 tests: onboarding/persistence/reset, Home, Leagues, receipt, denied GPS, foreground interruption, simulated driving save/reload, status/footer clearance, vehicle picker/account isolation, and Walking Test save/reload/exclusion.
- 159 portable checks passed: 34 sensor/GPS/persistence, 45 backend/auth/progress/serialization, 30 vehicle catalog, 50 isolated calculation/retry/error cases.
- Live four-account API check passed: unique identities, create/join, four members, restored sessions, each driver's own empty progress, individual unranked standings. Only a new dedicated test league was touched; no trips, deletes, or resets were sent by this check.
- Live UI check passed: a new online QA driver selected/saved a 2020 Toyota CAMRY, received a server-priced synthetic receipt under a separate calculation account, expanded assumptions, and returned to unchanged driver/car and empty Online Home progress. The server returned **$0.0624**, pricing vehicle **2020 Toyota CAMRY**, and model `notion-mazda5-2012-auto-v1`. These are experimental demo estimates, not measured fuel use or achieved savings.
- Online welcome and Keychain restoration after relaunch passed on the larger iPhone simulator. Accessibility XXXL footer/navigation clearance also passed.
- A separate simulated walking route passed through Core Location on the larger simulator: distance/accuracy/status, disabled driving events, and a no-fuel Walking Test receipt. This is an injected route, not a physical GPS accuracy test.

[Online Home screenshot](DesignPreviews/home-online.png) · [Synthetic server receipt screenshot](DesignPreviews/test-calculation.png)

## Rehearsal on four iPhones

1. Each person launches Online mode and registers once with a distinct nickname. Existing Keychain identities persist; do not reset real accounts for filming.
2. One person creates a league and shares its full invitation. The other three use Join League and paste the invitation. Refresh Leagues to show four individually named drivers. Without eligible baselines, show the truthful unranked state.
3. Profile → My Vehicle → choose/save a supported car → Test Calculation. Keep **Synthetic / Demo**, the actual pricing vehicle, and the returned estimate visible. Expand **How it’s calculated** if needed.
4. Return Home: isolated calculation tests do not populate the driver's savings or real driving history. Record the clean empty state if no legitimate results exist.
5. Show Start Trip or a Walking GPS Test only while stopped. A walking test validates the GPS path, not driving-event or fuel accuracy.

## Remaining limits / teammate dependencies

- Backend teammate owns eligible baseline/ranking results and deployment behavior. Four members enable a league, but do not create priced baselines or rankings by themselves. No baseline trips or financial values were fabricated for the video.
- Analytics teammate still owns fuel-model validation. The returned model version and accuracy warning are shown verbatim; the iOS app does not adjust calculations.
- The existing recorder/upload path does not assert the newly required whole-trip `events_complete` and top-level `detector_version` for old/local recordings. Those recordings may be accepted but unscored. Do not assert completeness without verified detector coverage; the latest backend sample used by Test Calculation includes the required metadata.
- No physical driving accuracy, physical-iPhone GPS accuracy, or continuous background recording is claimed. The recorder remains foreground-only. A physical four-phone rehearsal and the demo network should be checked before filming.
