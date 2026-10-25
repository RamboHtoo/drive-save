#!/bin/bash
# A sample display row must not type-check as a driving API upload.
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /tmp/drivesave-presentation-boundary.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
cat > "$test_dir/Rejected.swift" <<'SWIFT'
func cannotUploadSample() throws {
    _ = try TripUploadBuilder.payload(for: PresentationData.trips[0])
}
SWIFT
if swiftc -typecheck -module-cache-path /tmp/drive-save-module-cache \
    DriveAndSave/Models/DrivingModels.swift DriveAndSave/Models/RecordingModels.swift \
    DriveAndSave/Models/BackendModels.swift DriveAndSave/Models/PresentationData.swift \
    DriveAndSave/Services/TripUploadBuilder.swift "$test_dir/Rejected.swift" > "$test_dir/output" 2>&1; then
    echo 'FAIL: presentation trip unexpectedly accepted by the upload builder'; exit 1
fi
if ! rg -q "cannot convert value of type 'PresentationData.SampleTrip' to expected argument type 'Trip'" "$test_dir/output"; then
    cat "$test_dir/output"; exit 1
fi
echo 'PASS: sample display trips cannot compile as driving API uploads.'
