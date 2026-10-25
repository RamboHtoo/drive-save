# My Vehicle

Profile → My Vehicle → Choose vehicle → Brand → Model → Year → Save.

## Contract inspected

Read the backend branch at commit [`9254aa920b2b82fb168e181e443d08838073aabd`](https://github.com/RamboHtoo/drive-save/tree/9254aa920b2b82fb168e181e443d08838073aabd):

- [`docs/api.md`](https://github.com/RamboHtoo/drive-save/blob/9254aa920b2b82fb168e181e443d08838073aabd/docs/api.md) (the requested `backend/docs/api.md` path is no longer present)
- [`backend/models/vehicles.py`](https://github.com/RamboHtoo/drive-save/blob/9254aa920b2b82fb168e181e443d08838073aabd/backend/models/vehicles.py)
- [`backend/routes/vehicles.py`](https://github.com/RamboHtoo/drive-save/blob/9254aa920b2b82fb168e181e443d08838073aabd/backend/routes/vehicles.py), `backend/routes/users.py`, `backend/models/users.py`, and `docs/vehicle-catalog.md`.

Catalog GETs need no authentication:

| Request | Response |
| --- | --- |
| `/vehicles/makes` | `makes` |
| `/vehicles/models?make=` | `make`, `models` |
| `/vehicles/years?make=&model=` | `make`, `model`, `years` |
| `/vehicles/details?make=&model=&year=` | Complete vehicle object |

`URLComponents` encodes query values; literal `+` is explicitly encoded as `%2B`. Model names containing spaces, slashes, ampersands, hashes, and plus signs remain intact. No search or variant endpoints were invented; search filters the fetched choices locally.

Saving sends the **entire original details object** to authenticated `PUT /users/me/vehicle`, including `vehicle_id`, `make`, `model`, `year`, `supported`, `specs`, `mpg`, `parameters`, `flags`, `source`, and any future unknown fields. Typed fields are only a display projection. Nothing is recomputed in Swift. `GET /users/me/vehicle` refreshes the saved server selection; `404 vehicle_not_set` is an empty profile, not a failure.

## Behavior

- Searchable Brand, Model, and Year sheets show loading, empty results, errors, and Retry. Selection remains unavailable until its prerequisite is chosen.
- Changing Brand clears Model, Year, and details. Changing Model clears Year and details. Old/cancelled detail responses cannot reappear after changing choices. Reselecting the same Year retains loaded details.
- Save appears only after complete details load. Failed saves leave the previous saved vehicle intact and offer the same draft for retry.
- The summary displays backend-provided year/brand/model, available MPG, fuel, engine/cylinders, power, transmission, drive, test weight, source, and catalog caveats. Missing MPG is never replaced with zero. EPA-derived estimates are labeled.
- Unsupported cars can be stored as the driver's car, but show **Fuel estimates unavailable for this vehicle**. Real pricing uploads are rejected before network access when the catalog says unsupported. This does not change driving telemetry or local recording.
- `supported` only describes catalog/model support. Vehicle-specific pricing is experimental and remains backend work. Selecting a car does not turn Home's sample financial aggregate into a real measurement.
- Saved selections are keyed by server/mode and user ID in the existing protected local state file. They survive relaunch and do not transfer to reset accounts or between online/offline modes. Legacy single-car caches migrate once into their existing account/mode.
- Advanced Settings retains raw JSON editing/import, the original EPA example, explicit upload/fetch controls, and isolated demo replay. Unsynced imports remain local drafts until explicitly uploaded, so background refresh does not silently replace them.
- The offline catalog contains only two **real captured public catalog responses**, labeled sample data: 2012 Mazda MAZDA5 and 2026 Tesla Cybertruck AWD. These were captured on 2026-10-24 from the deployed API. Their specifications/parameters are preserved exactly; they are not invented vehicles or claimed road measurements.
- Authentication, Keychain storage, trip snapshots/idempotency, receipt rendering, leagues, and sensor services retain their existing contracts. Newer trip/receipt financial-model contract migrations are outside this picker change.

## Tests

Portable catalog/client/selection checks (macOS with Xcode):

```sh
swiftc -module-cache-path /tmp/drive-save-module-cache \
  DriveAndSave/Models/{DrivingModels,RecordingModels,BackendModels,VehicleCatalogModels}.swift \
  DriveAndSave/Services/{TripUploadBuilder,KeychainCredentialStore,BackendAPIClient}.swift \
  DriveAndSave/ViewModels/VehiclePickerViewModel.swift \
  Tests/VehicleCatalogTests.swift -o /tmp/drivesave-vehicle-tests
/tmp/drivesave-vehicle-tests
```

These cover all four catalog requests, exact query encoding, unknown JSON-field preservation, protected PUT/GET, empty/error handling, unsupported uploads, save readiness, selection resets, stale responses, same-year reselection, persistence encoding, and retry.

`DriveAndSaveUITests/VehiclePickerTests.swift` uses an isolated offline account and the captured fixtures to verify search/no-results, all selection steps, full details, Save, restart, Profile rendering, dependent selection clearing, unsupported EV labels, and confirmed-account-reset isolation. Existing regression tests cover recording, GPS denial, interruptions, Walking Test persistence/exclusion, Keychain accounts, leagues, receipts, and navigation/accessibility text sizes.

`Tests/VehicleCatalogLiveSmoke.swift` is explicitly opt-in (`--live`). Compile with the backend model/service sources above, omit the picker view model, and replace the test filename. It creates **one new dedicated test user**, saves a public catalog vehicle, restores its identity through an in-memory credential store, and verifies GET returns the identical full object. It submits no trips, joins no leagues, changes no existing user, and never prints tokens. The test account remains on the server. Keychain relaunch is checked separately through the UI tests.

## Physical iPhone check

1. Run the signed app from Xcode on your iPhone. Use your online account; if currently offline, Profile → Advanced Settings → Use remote backend → Apply connection, then complete welcome if necessary.
2. Open Home → Profile → My Vehicle → Choose vehicle. Search for your actual Brand, Model, and Year.
3. Check the details and EPA estimate label; tap Save. Go back to Profile and verify the saved car.
4. Close and reopen the app. The same account and vehicle should remain. My Vehicle also pulls to refresh its server selection.
5. Change Brand: old Model/Year and Save must clear. Changing Model must clear Year. Cancel without saving to keep the previous car.
6. Turn on Airplane Mode, try a catalog request, and confirm the error/Retry state. The previous saved car should remain. Reconnect and retry.
7. An unsupported catalog car can be saved, but must show the unavailable-for-fuel-estimates warning. No drive or phone movement is required to test the picker.

No physical-device run or vehicle-specific fuel accuracy is claimed by the automated tests.

## Verification results (2026-10-24)

- Incremental catalog-only and full-picker simulator builds succeeded; final picker build also passed.
- 30 catalog/client/selection checks, 34 backend regression checks, and 34 recording/GPS/persistence checks passed (98 total).
- VehiclePickerTests passed on iPhone 17e, including search/no-results, Save/relaunch, same-year reselection, unsupported EV, and account reset isolation.
- All 12 existing offline UI regression tests passed on iPhone 17 Pro Max, including largest accessibility text, recording/simulated trip reload, GPS denial, interruptions, Walking Test persistence/exclusion, registration/reset, vehicle replay, receipt, leagues, and safe navigation (13 distinct UI tests including the picker).
- Live API GETs for brands/models/years/details passed. Dedicated test-user PUT and fresh-client GET returned the identical full vehicle object. No trips or league changes were submitted.
- [Picker screenshot](DesignPreviews/vehicle-picker.png) is an isolated offline fixture preview, not a real user's car or financial measurement.
