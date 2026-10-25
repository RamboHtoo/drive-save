"""Offline Swift/Python compatibility probe. No HTTP, credentials, database or writes to backend.

First run RecordingContractTests.swift to produce serializer payloads, then:
  python3 Tests/check_recording_compatibility.py --backend /path/to/backend-snapshot \
      --payloads /tmp/drivesave-recording-contract
Requires the backend's Python dependencies (numpy, pydantic). The snapshot must contain
backend/ and drive_save_model/. Fixture checks do not establish physical sensor accuracy.
Use --recording /path/to/export.json to inspect a real iOS Developer Mode export locally.
"""
import argparse
import json
from pathlib import Path
import sys
from uuid import uuid4

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--backend", type=Path, required=True)
parser.add_argument("--payloads", type=Path, default=Path("/tmp/drivesave-recording-contract"))
parser.add_argument("--recording", type=Path)
args = parser.parse_args()
sys.path[:0] = [str(args.backend.resolve() / "backend"), str(args.backend.resolve())]
from models.trips import TripCreate
from services.cost_model import PricingRequest, SCORING_CONFIG, build_input, estimate


def evaluate(path):
    raw = json.loads(path.read_text())
    trip = TripCreate.model_validate(raw)
    # Matches backend repo.accept_trip's current DEMO_ONLY policy. Never rewrite the JSON
    # source/provenance, speed samples, distances or timestamps to make the model pass.
    model_trip = trip.model_copy(update={"is_demo": True})
    result = estimate(build_input(PricingRequest(uuid4(), model_trip, SCORING_CONFIG["vehicle_profile"])))
    print(f"{path.name}: {result.status}; reasons={result.quality_flags}")
    return raw, result


if args.recording:
    _, result = evaluate(args.recording)
    print("Read-only evaluation of exported data; no trip was uploaded.")
    if result.status != "scored":
        assert result.avoidable_usd is None and result.fuel_gal is None
else:
    full, result = evaluate(args.payloads / "complete-fixture.json")
    assert full["source"] == "replayed" and full["is_demo"] is True
    assert full["events_complete"] is True and full["detector_version"] == "ios-0.3.0"
    assert result.status == "scored" and result.avoidable_usd is not None
    for name in ["boundary-gap-fixture", "recorded-mode-fixture", "asynchronous-fixture", "three-second-edges-fixture"]:
        raw, result = evaluate(args.payloads / (name + ".json"))
        assert raw["speed_samples"] == full["speed_samples"]
        if name == "recorded-mode-fixture":
            assert raw["source"] == "recorded" and raw["is_demo"] is False
        assert result.status == "scored" and result.avoidable_usd is not None
    for name, reason in [
        ("excess-edge-fixture", "gps_boundary_gap_over_three_seconds"),
        ("sparse-fixture", "valid_time_coverage_below_95_percent"),
        ("interior-gap-fixture", "gps_gap_over_three_seconds"),
        ("inaccurate-fixture", "insufficient_valid_speed"),
        ("incomplete-fixture", "event_recording_incomplete"),
    ]:
        _, result = evaluate(args.payloads / (name + ".json"))
        assert result.status == "insufficient_data" and reason in result.quality_flags
        assert result.avoidable_usd is None and result.fuel_gal is None
    print("PASS: ten Swift-generated payloads validated through backend TripCreate, build_input and fuel model.")
    print("Controlled synthetic compatibility evidence only. No physical iPhone recording supplied or uploaded.")
