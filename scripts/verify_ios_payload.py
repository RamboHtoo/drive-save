"""Read-only GPS/model verification of an iOS POST /trips JSON payload.

No source, demo, completeness, speed, or timestamp fields are repaired. This
script never uploads data. GPS gates can pass even when other model gates fail.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from drive_save_model import estimate_trip, reference_profile, scoring_config
from drive_save_model.trace import TraceError, prepare_trace


def model_input(payload, profile, config):
    return {"vehicle_profile": profile, "scoring_config": config,
            "speed_samples": payload.get("speed_samples"), "events": payload.get("events"),
            "trip_metadata": {k: payload.get(k) for k in (
                "started_at", "ended_at", "distance_mi", "source", "is_demo",
                "events_complete", "detector_version")}}


def verify(payload, profile, config):
    inputs = model_input(payload, profile, config)
    try:
        _, _, trace = prepare_trace(inputs["speed_samples"], inputs["trip_metadata"])
        gps = {"status": "accepted", "trace": trace}
    except TraceError as exc:
        gps = {"status": "insufficient_data", "reason": str(exc)}
    result = estimate_trip(**inputs)
    return {"source": payload.get("source"), "is_demo": payload.get("is_demo"),
            "gps": gps, "model": result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("payload", type=Path, help="Unmodified iOS POST /trips JSON")
    parser.add_argument("--config", type=Path, help="Backend scoring config JSON; includes vehicle_profile")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    raw = args.payload.read_bytes()
    payload = json.loads(raw)
    if not isinstance(payload, dict) or not {"started_at", "ended_at", "speed_samples"} <= payload.keys():
        parser.error("Expected a POST /trips payload, not the older debug archive or a receipt.")
    config = (json.loads(args.config.read_text()) if args.config else
              scoring_config(3.50, price_as_of="2026-10-25", vehicle_profile=reference_profile()))
    result = verify(payload, config["vehicle_profile"], config)
    result["input_sha256"] = hashlib.sha256(raw).hexdigest()
    result["configuration_source"] = "supplied_backend_config" if args.config else "reference_car_test_config"
    output = json.dumps(result, indent=2, allow_nan=False) + "\n"
    if args.output:
        args.output.write_text(output)
    else:
        print(output, end="")
    return 0 if result["model"]["status"] == "scored" else 2


if __name__ == "__main__":
    raise SystemExit(main())
