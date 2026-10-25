# Drive Save backend integration

Contract: https://github.com/RamboHtoo/drive-save/blob/backend/docs/api.md
Production: https://drivesave.nuhylabs.com

Inspected the backend branch's documentation, Pydantic trip/user/vehicle/league models, routes and scoring service, plus deployed `/health` and `/openapi.json`. Bundled fixtures under `DriveAndSave/MockData/Backend` are the supplied backend files, not invented vehicle/trip values.

## Model gaps found before implementation

| Existing iOS data | Contract integration |
| --- | --- |
| Local trip UUID created on completion | Separate `clientTripID` generated at recording start and persisted |
| Events with count, magnitude and detection timestamp | Stable event UUID, observed window start/duration, detector version, peak g, GPS before/after speed evidence |
| GPS point speed only | Separate timestamped speed samples, speed accuracy, sequence counter; invalid readings become JSON null |
| Local receipt assumptions | Exact server receipt, event costs, `cost_model`, `is_estimate`, dated/source-linked assumptions |
| Mock crew-against-crew standings | Private leagues, individual drivers, membership/invites, 4+ gate |
| Generic configurable API adapters | Concrete contract API with protected requests and Keychain sessions |

Old recordings without required metadata remain readable locally but are not fabricated into uploadable trips. Walking Tests are rejected by the upload builder. Incomplete recordings, invalid/nonfinite values, excessive speed/event counts and missing before/after speed evidence are rejected with a reason.

## Contract updated during implementation

The first contract/OpenAPI inspection used `scope`, `id`, and `name` on the leaderboard. The backend branch and deployment changed while work was in progress. The re-fetched source (leaderboard models/docs modified 2026-10-24 21:45:25 UTC) and live schema now return:

- League: `crew_id`, `crew_name`, `member_count`, `active`, `period`, `generated_at`, `standings`, `is_demo`, `is_estimate`.
- Driver: nullable `rank`, `user_id`, `nickname`, nullable `improvement_pct`, `est_savings_usd`, `trips_counted`.
- The live handler resolves the caller's league implicitly. It accepts `period`; the earlier `scope=members&crew_id=...` query is obsolete. iOS follows the updated source of truth with `GET /leaderboard`, and verifies the returned `crew_id` before displaying data. It never requests a crew-against-crew board.

The app follows the verified updated response rather than inventing a fallback shape. Unranked drivers show “Awaiting baseline”; ranks are never invented. Leagues with fewer than four members are not ranked in the UI.

## Authentication

`BackendAPIClient` is an actor. `POST /users` sends only `nickname`. The returned token, user ID, nickname, and demo-recovery preference are stored in Keychain, scoped by API base URL, with `WhenUnlockedThisDeviceOnly` protection. UI receives only user ID/nickname. Tokens are never logged or written to UserDefaults, JSON files, or this repository. The non-secret connection mode/base URL and per-user league ID are persisted locally; credentials remain in Keychain.

Protected requests include `Authorization: Bearer ...`. A demo-account 401 triggers one re-registration and one retry. The selected vehicle is restored before retrying protected uploads. A clear reset notice explains that old server trips/membership may be gone while local history remains. Non-demo sessions require manual registration. No server-reset endpoint is called.

## Welcome, Profile, and four-device leagues

Welcome now handles first-use nickname registration through the existing POST /users client. Startup restores the selected mode and its saved Keychain identity before deciding whether to show Welcome. Remote multiplayer is the default on a fresh install; offline demo is an explicit choice. The same real Keychain account names used by the previous remote client are preserved for migration. Ordinary sessions are never replaced automatically; optional development demo recovery retains the existing one-retry 401 behavior and now presents a prominent reset alert.

`BackendAPIClient.register` refuses to overwrite a saved identity. Only Profile’s confirmed development reset clears that mode’s credentials. This is a local sign-in reset, not a rename, login, server reset, or delete endpoint. Local trip history and the other mode’s sign-in remain intact. Offline credentials are persisted to a separate Keychain entry, and the offline example league is restored locally. This does not turn offline mock mode into a multiplayer server.

Profile is accessible from Home and Leagues. It shows nickname, user ID, member count and invitation actions; online/offline switching is available there without the technical screen. Leagues supports pull-to-refresh and explicit refresh. Copy/Share includes both the UUID and join code required by the API; Join League parses this local invitation format into those exact request values. No code-only lookup or new endpoint is invented. Driver names and nullable ranks use the current deployed member leaderboard.

Tests use unique `--account-test-id=...` Keychain and local API-state namespaces, so first-launch checks never clear a real driver’s credentials. The live four-account check creates only new dedicated accounts and one new private league, uploads no trips, and verifies distinct user IDs, counts 1→4, shared member lists, active league status, and unranked drivers awaiting baselines. Device Keychain behavior is checked separately through the signed remote welcome UI and relaunch test.

## Critical server gap and replay isolation

The inspected backend scoring service and live progress endpoint currently count `is_demo` trips in progress. Marking a replay alone does not prevent future ranking contamination.

Therefore all app replay/simulated uploads use a separate Keychain identity with `demoOnly: true`. That client rejects real uploads and cannot create or join leagues. The normal driver client rejects demo uploads. Replay requests always use `source: replayed`, `is_demo: true`. This protects the normal driver's rankings in this app. Server-side exclusion is still required to protect against other clients or historical mixed data. `/backend` was not changed.

The earlier two-member production smoke test uploads replay only under an isolated dedicated account with no league. Its private-league tests use different dedicated users with no replay trips and leave the league inactive at two members. No existing users/leagues/trips are modified or deleted.

## Vehicle

API & Vehicle supports the supplied authentic EPA example and importing a complete EPA JSON row. Every key/value is preserved, including road-load coefficient names. The example is explicitly not assumed to be the user's actual vehicle. Real uploads require the user to confirm that the selected row matches their car. No full EPA catalog was supplied; a make/model catalog browser is not implemented.

`PUT /users/me/vehicle` always precedes a trip POST. Vehicle and complete trip payload are frozen locally before the first attempt, so retrying after a profile change restores the original vehicle snapshot before submitting. GET loads the server profile for viewing/updating. Objects are constrained to 1–200 fields and less than 20 KB as specified.

## Trip serialization and receipts

Wire DTOs are separate from local recordings. API JSON uses exact snake_case names and fractional UTC ISO 8601 timestamps. No latitude, longitude, local raw sensor objects, MPG placeholders, or dollar estimates enter `APITripPayload`. The receipt's API JSON export uses the same validated serializer.

New device recordings request frequent GPS updates and log speed and speed accuracy before spatial-distance filtering; availability still depends on iOS. Sample sequence numbers are unique and persisted. Invalid/out-of-range speeds and invalid accuracies become null. Software-simulated Core Location readings mark the local trip simulated; they cannot be sent as real competition input.

Candidate event peaks are over the observed qualifying window, converted from m/s² to g. Duration is that observed window, not a claim that the entire physical maneuver was measured. Before/after speeds must be supported by GPS within ten seconds. Sharp turns include heading change only when valid course data is available. Physical driving accuracy is unvalidated.

`201` and duplicate `200` decode `trip_id`, `receipt_url`, `duplicate`. The response trip ID is persisted before fetching `GET /trips/{id}/receipt`. Network/receipt failures keep the frozen record for manual retry. 409 conflicts remain conflicts; no fresh UUID is silently invented. 422 errors include field locations. All JSON numeric values are finite or explicitly null.

Receipts show returned costs, per-event values, `cost_model`, `is_estimate`, and assumptions. `flat_per_event` prominently displays **PLACEHOLDER PRICING**, explicitly not measured fuel waste or achieved savings. Offline mock receipts are labeled; they are never represented as remote responses.

## Files added

- `Models/BackendModels.swift`: exact wire models, JSON date codec and fixture loader.
- `Services/KeychainCredentialStore.swift`: secure scoped credentials.
- `Services/BackendAPIClient.swift`: concrete contract endpoints and explicit mock/remote modes.
- `Services/TripUploadBuilder.swift`: privacy-safe conversion and eligibility checks.
- `ViewModels/BackendViewModel.swift`: registration, vehicle, durable retry snapshots, receipts and membership state.
- `Views/APISettingsView.swift`: API registration, vehicle import/update, isolated replay and server receipt components.
- `MockData/Backend/sample-{trip,vehicle,receipt}.json`: exact supplied backend fixtures.
- `Tests/BackendTests.swift`: contract/HTTP/retry/privacy tests with URLProtocol stubs.
- `Tests/production_smoke.py`: opt-in dedicated-account live verification; never prints/stores tokens.

Existing recording models/service, app environment, Home/receipt/history/league views, shared scroll layout, and UI tests were updated. All file changes are inside `/ios`.

## Verification results

- Signed Xcode simulator build succeeded. Actual Keychain registration/restoration passed across app termination/relaunch using a dedicated demo user and isolated test Keychain namespace. Unsigned builds do not have the required Keychain entitlement; use normal signed Xcode Run for remote auth.
- 34 existing model/GPS/persistence checks and 25 contract/serialization/HTTP checks passed.
- Eight distinct UI flows passed in batches: offline API/vehicle/replay/placeholder receipt/league; recorded permission denial; foreground interruption; tab interruption; simulated driving and persistence; walking history filtering/persistence/unchanged standings; signed remote Keychain restoration; Core Location walking route. The walking flow asserts the save control is above the native tab bar. GPS screenshots were visually checked.
- `Tests/LiveClientSmoke.swift` exercised the actual Swift API client against production using dedicated users: registration, vehicle-first upload and GET, replay 201/duplicate 200, receipt decoding, isolated-account league rejection, separate league create/join/read, member leaderboard decoding and unranked drivers. Tokens stayed only in test process memory; no replay user joined a league.
- `Tests/production_smoke.py` verified live 401/409/422 status paths and validation details in addition to the successful endpoints. No production reset/delete operations were used. Test leagues remain inactive, with no synthetic trips under their members.
- Real on-road accuracy and a four-real-driver ranked competition were not tested. Home financial charts remain demo data. Server pricing remains `flat_per_event`; server demo-trip filtering is still a backend issue. A full searchable EPA catalog was not supplied; complete row import and the authentic supplied example are implemented.
