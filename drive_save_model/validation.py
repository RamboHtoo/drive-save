"""Reproducible formula demonstrations and explicitly limited lab comparisons."""
from datetime import datetime, timedelta, timezone
import json
from uuid import NAMESPACE_URL, uuid5

import numpy as np

from .physics import DATA, MPH_TO_MPS, diagnostic_cycle_fuel
from .estimator import estimate_trip, reference_profile, scoring_config
from .trace import METERS_PER_MILE


def load_cycle(name):
    if name not in ("udds", "hwfet", "us06"):
        raise ValueError("cycle must be udds, hwfet, or us06")
    values = []
    for line in (DATA / (name + "_epa.txt")).read_text().splitlines():
        parts = line.split()
        if len(parts) == 2:
            try:
                values.append((float(parts[0]), float(parts[1]) * MPH_TO_MPS))
            except ValueError:
                pass
    return np.array(values).T


def payload_from_trace(time, speed, *, source="synthetic"):
    start = datetime(2026, 10, 19, 12, tzinfo=timezone.utc)
    return {
        "vehicle_profile": reference_profile(),
        "scoring_config": scoring_config(3.50, price_as_of="2026-10-24"),
        "trip_metadata": {"started_at": start.isoformat(),
            "ended_at": (start + timedelta(seconds=float(time[-1]))).isoformat(),
            "distance_mi": float(np.trapezoid(speed, time) / METERS_PER_MILE),
            "source": source, "is_demo": True, "events_complete": True,
            "detector_version": "synthetic-fixture-v1"},
        "speed_samples": [{"ts": (start + timedelta(seconds=float(t))).isoformat(),
            "sample_seq": i, "speed_mps": float(v), "speed_accuracy_mps": 0.0}
            for i, (t, v) in enumerate(zip(time, speed))],
        "events": [],
    }


def example_payload(name="demo"):
    if name != "demo":
        time, speed = load_cycle(name)
        payload = payload_from_trace(time, speed, source="replayed")
        # Published speed schedules contain no phone IMU/detector completion data.
        payload["trip_metadata"].update(events_complete=False, detector_version="speed-replay-no-imu")
        return payload
    time = np.arange(301, dtype=float)
    speed = np.interp(time, [0, 30, 33, 60, 66, 80, 100, 120, 300],
                     np.array([34, 34, 12, 12, 45, 21, 21, 75, 75]) * MPH_TO_MPS)
    payload = payload_from_trace(time, speed)
    for kind, t, duration, before, after, peak in (
        ("harsh_brake", 30, 3, 34, 12, 0.34),
        ("rapid_accel", 60, 6, 12, 45, 0.30),
        ("sharp_turn", 90, 4, 21, 21, 0.44),
    ):
        payload["events"].append({"event_id": str(uuid5(NAMESPACE_URL, "drive-save:demo:" + kind)),
            "ts": payload["speed_samples"][t]["ts"], "duration_s": duration, "type": kind,
            "speed_before_mph": before, "speed_after_mph": after, "peak_g": peak,
            "detector_version": "synthetic-fixture-v1"})
    return payload


def cruise_payload(mph=75):
    return payload_from_trace(np.arange(301, dtype=float), np.full(301, mph * MPH_TO_MPS))


def validation_report():
    profile = reference_profile()
    rows = json.loads((DATA / "epa_2012_mazda5.json").read_text())
    results = []
    for cycle, category in (("hwfet", "HWY"), ("us06", "US06")):
        time, speed = load_cycle(cycle)
        distance = float(np.trapezoid(speed, time) / METERS_PER_MILE)
        gallons = diagnostic_cycle_fuel(time, speed, profile)
        row = next(r for r in rows if r["Test Category"] == category)
        observed_mpg = float(row["RND_ADJ_FE"])
        comparison_gal = distance / observed_mpg
        results.append({"cycle": cycle, "test_number": row["Test Number"],
            "published_lab_mpg": observed_mpg, "diagnostic_predicted_mpg": distance / gallons,
            "diagnostic_predicted_gal": gallons, "schedule_distance_mi": distance,
            "nominal_schedule_reference_gal": comparison_gal,
            "nominal_fuel_error_pct": 100 * (gallons - comparison_gal) / comparison_gal,
            "limitation": "Nominal schedule versus rounded lab result; actual driven trace and thermal state unavailable"})
    return {"validation_status": "laboratory_validation_pending", "release_gate_passed": False,
        "vehicle_profile": profile, "calibration_applied": False,
        "real_world_accuracy": "unverified", "event_savings_accuracy": "unverified",
        "formula_checks_are_accuracy_validation": False, "laboratory_comparisons": results,
        "ftp": {"published_mpg": 26.4, "comparison_status": "not_comparable_to_single_udds",
                "reason": "FTP includes weighted cold/hot phases; model has no cold-start behavior"},
        "next_data_required": ["Measured fuel with synchronized speed for the test car",
                               "Separate measured trips for evaluating total fuel and savings differences"]}


def four_player_demo():
    baseline = estimate_trip(**cruise_payload(75))
    baseline_miles = cruise_payload(75)["trip_metadata"]["distance_mi"]
    rate = baseline["avoidable_usd"] / baseline_miles
    standings = []
    for name, mph in (("Demo Alex", 65), ("Demo Blair", 68), ("Demo Casey", 71), ("Demo Drew", 75)):
        payload = cruise_payload(mph)
        result = estimate_trip(**payload)
        if result["status"] != "scored":
            raise RuntimeError(json.dumps(result))
        miles = payload["trip_metadata"]["distance_mi"]
        later_rate = result["avoidable_usd"] / miles
        standings.append({"nickname": name, "baseline_trip_count": 3, "baseline_usd_per_mile": rate,
            "weekly_usd_per_mile": later_rate, "later_distance_mi": miles,
            "improvement_pct": 100 * (rate-later_rate) / rate,
            "est_savings_usd": rate * miles - result["avoidable_usd"], "is_demo": True, "receipt": result})
    standings.sort(key=lambda r: r["improvement_pct"], reverse=True)
    for rank, row in enumerate(standings, 1):
        row["rank"] = rank
    return {"is_demo": True, "data_source": "Synthetic constant-speed scenarios; no real drivers",
        "baseline_method": "Three 75 mph synthetic baseline trips; later comparisons at 65, 68, 71, 75 mph",
        "standings": standings, "validation_status": "laboratory_validation_pending"}
