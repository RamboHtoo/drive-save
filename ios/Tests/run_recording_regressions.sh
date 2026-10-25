#!/bin/bash
# Offline only. Run from /ios; optional argument is a read-only backend checkout/snapshot.
set -euo pipefail
cd "$(dirname "$0")/.."
recording_build_dir=$(mktemp -d /tmp/drivesave-recording-tests.XXXXXX)
models=DriveAndSave/Models
services=DriveAndSave/Services
common=("$models/DrivingModels.swift" "$models/RecordingModels.swift" "$models/BackendModels.swift")
api=("$services/TripUploadBuilder.swift" "$services/KeychainCredentialStore.swift" "$services/BackendAPIClient.swift")
run_suite() {
    local name=$1
    shift
    swiftc -module-cache-path /tmp/drive-save-module-cache "$@" -o "$recording_build_dir/$name"
    "$recording_build_dir/$name" > "$recording_build_dir/$name.log"
    tail -1 "$recording_build_dir/$name.log"
}
run_suite models "${common[@]}" "$models/TripExportPayload.swift" "$services/TripStore.swift" "$services/APIClient.swift" DriveAndSave/MockData/DemoData.swift Tests/main.swift
run_suite backend "${common[@]}" "$models/VehicleCatalogModels.swift" "$models/LeagueInvitation.swift" "${api[@]}" DriveAndSave/MockData/DemoData.swift Tests/BackendTests.swift
run_suite vehicles "${common[@]}" "$models/VehicleCatalogModels.swift" "${api[@]}" DriveAndSave/ViewModels/VehiclePickerViewModel.swift Tests/VehicleCatalogTests.swift
run_suite calculation "${common[@]}" "$models/VehicleCatalogModels.swift" "$models/TestCalculationModels.swift" "${api[@]}" "$services/TestCalculationService.swift" DriveAndSave/ViewModels/TestCalculationViewModel.swift Tests/TestCalculationTests.swift
run_suite history "${common[@]}" "$models/TripExportPayload.swift" "$services/TripStore.swift" "$services/APIClient.swift" DriveAndSave/MockData/DemoData.swift DriveAndSave/ViewModels/AppViewModel.swift Tests/TripHistoryTests.swift
run_suite leagues "${common[@]}" "$models/VehicleCatalogModels.swift" "$models/TestCalculationModels.swift" "${api[@]}" "$services/TestCalculationService.swift" DriveAndSave/ViewModels/BackendViewModel.swift Tests/LeagueIntegrationTests.swift
run_suite recording "${common[@]}" "$services/TripUploadBuilder.swift" Tests/RecordingContractTests.swift
run_suite v2 "${common[@]}" Tests/V2IntegrationTests.swift
run_suite telemetry "${common[@]}" "$models/LiveTelemetry.swift" Tests/LiveTelemetryTests.swift
if [ "$#" -gt 0 ]; then
    "${PYTHON:-python3}" Tests/check_recording_compatibility.py --backend "$1"
fi
printf 'Offline logs: %s\n' "$recording_build_dir"
