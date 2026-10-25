"""Rebuild the synthetic fixture with the actual, pinned iOS upload code.

Requires Swift on macOS and the iOS commit in this repository. No network calls,
branch changes, iOS source edits, device data, or backend writes.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
IOS_COMMIT = "99c07bad52a38137255d004e24993501223c3f9a"
SOURCES = [
    "ios/DriveAndSave/Models/BackendModels.swift",
    "ios/DriveAndSave/Models/DrivingModels.swift",
    "ios/DriveAndSave/Models/RecordingModels.swift",
    "ios/DriveAndSave/Services/TripUploadBuilder.swift",
]


def main():
    destination = ROOT / "tests/fixtures/ios"
    hashes = {}
    with tempfile.TemporaryDirectory(prefix="drive-save-swift-gps-") as name:
        build = Path(name)
        files = []
        for path in SOURCES:
            source = subprocess.check_output(["git", "show", f"{IOS_COMMIT}:{path}"], cwd=ROOT)
            hashes[path] = hashlib.sha256(source).hexdigest()
            target = build / Path(path).name
            target.write_bytes(source)
            files.append(str(target))
        harness = (destination / "generate.swift").read_bytes()
        (build / "main.swift").write_bytes(harness)
        subprocess.run(["swiftc", "-module-cache-path", str(build / "module-cache"),
                        *files, str(build / "main.swift"), "-o", str(build / "generate")], check=True)
        wire = subprocess.check_output([str(build / "generate")])
    payload = json.loads(wire)
    assert payload["source"] == "replayed" and payload["is_demo"] is True
    (destination / "swift-async-replay.json").write_bytes(wire + b"\n")
    manifest = {"ios_commit": IOS_COMMIT, "source_sha256": hashes,
                "generator_sha256": hashlib.sha256(harness).hexdigest(),
                "payload_sha256": hashlib.sha256(wire + b"\n").hexdigest(),
                "provenance": "Actual iOS upload builder and encoder; synthetic observations executed on macOS.",
                "real_device_recording": False,
                "session_seconds": 301, "first_gps_offset_s": .625, "last_gps_offset_s": 300.625}
    (destination / "provenance.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("Generated Swift replay fixture (synthetic, not a device recording).")


if __name__ == "__main__":
    main()
