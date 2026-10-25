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
    assert full["events_complete"] is True and full["detector_version"] == "ios-0.2.0"
    assert result.status == "scored" and result.avoidable_usd is not None
    gap, result = evaluate(args.payloads / "boundary-gap-fixture.json")
    assert gap["speed_samples"] == full["speed_samples"]
    assert result.status == "insufficient_data" and "missing_boundary_speed" in result.quality_flags
    assert result.avoidable_usd is None and result.fuel_gal is None
    recorded, result = evaluate(args.payloads / "recorded-mode-fixture.json")
    assert recorded["source"] == "recorded" and recorded["is_demo"] is False
    assert recorded["speed_samples"] == full["speed_samples"]
    assert result.status == "insufficient_data" and "missing_boundary_speed" in result.quality_flags
    assert result.avoidable_usd is None and result.fuel_gal is None
    incomplete, result = evaluate(args.payloads / "incomplete-fixture.json")
    assert incomplete["events_complete"] is False
    assert result.status == "insufficient_data" and "event_recording_incomplete" in result.quality_flags
    assert result.avoidable_usd is None and result.fuel_gal is None
    print("PASS: four Swift-generated payloads validated through backend TripCreate, build_input and fuel model.")
    print("Fixture compatibility only; genuine button-boundary recordings remain blocked. No physical recording supplied.")
