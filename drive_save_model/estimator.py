"""Offline Mazda5 scenario estimates. Backend supplies trusted configuration.

Another car can be priced with the same equations when the backend supplies its
profile with all of its own parameters (physics.DEFAULT_PARAMETERS keys).
"""

import hashlib
import json
from uuid import NAMESPACE_URL, UUID, uuid5

import numpy as np

from .physics import (DATA, DEFAULT_PARAMETERS, G, MPH_TO_MPS, LBF_TO_N,
                      brake_scenario, acceleration_scenario, high_speed_scenario, parameters)
from .trace import TraceError, finite_number, prepare_trace, timestamp

MODEL_VERSION = "notion-mazda5-2012-auto-v1"
PROFILE_ID = "mazda5-2012-auto-31284-epa-config1"
NOTION_SOURCE = "https://app.notion.com/p/Cost-Model-Math-40309f8ad9ef81b29ec9e1043882320a"


def reference_profile():
    """The model's own car, the 2012 Mazda5, with the Notion parameters."""
    vehicle = json.loads((DATA / "fueleconomy_31284.json").read_text())
    records = json.loads((DATA / "epa_2012_mazda5.json").read_text())
    row = next(r for r in records if r["Test Category"] == "HWY")
    abc = [float(row[key]) for key in ("Target Coef A (lbf)", "Target Coef B (lbf/mph)", "Target Coef C (lbf/mph**2)")]
    return {
        "id": PROFILE_ID, "name": "2012 Mazda5 2.5L automatic (5-speed), FWD",
        "year": 2012, "make": "Mazda", "model": "5", "transmission": "Automatic (S5)",
        "fuel": "Regular Gasoline", "fuel_economy_vehicle_id": 31284,
        "configuration_match": "US 2.5L automatic; EPA test configuration 1",
        "test_vehicle_id": row["Test Vehicle ID"], "test_configuration": 1,
        "mass_kg": float(row["Equivalent Test Weight (lbs.)"]) * 0.45359237,
        "mass_basis": "EPA equivalent test weight; actual passenger/cargo mass unknown",
        "rated_horsepower": float(row["Rated Horsepower"]),
        "road_load_original": dict(zip(("a_lbf", "b_lbf_per_mph", "c_lbf_per_mph2"), abc)),
        "road_load_si": {"a_n": abc[0] * LBF_TO_N, "b_n_per_mps": abc[1] * LBF_TO_N / MPH_TO_MPS,
                         "c_n_per_mps2": abc[2] * LBF_TO_N / MPH_TO_MPS**2},
        "city_mpg": float(vehicle["city08"]), "highway_mpg": float(vehicle["highway08"]),
        "combined_mpg": float(vehicle["comb08"]),
        "source_hashes": {name: hashlib.sha256((DATA / name).read_bytes()).hexdigest()
                          for name in ("fueleconomy_31284.json", "epa_2012_mazda5.json")},
    }


def scoring_config(price_usd_per_gal, *, price_as_of, price_source_url=None, vehicle_profile=None):
    """vehicle_profile defaults to the Mazda5; another car's parameters replace the Notion values."""
    from decimal import Decimal
    from datetime import date
    if not finite_number(price_usd_per_gal) or not 0 <= price_usd_per_gal <= 100:
        raise ValueError("price must be finite USD/US-gallon between 0 and 100")
    price = Decimal(str(price_usd_per_gal))
    if price != price.quantize(Decimal("0.000001")):
        raise ValueError("price must have at most six decimal places")
    if price_source_url is not None and not isinstance(price_source_url, str):
        raise ValueError("price source must be text or null")
    date.fromisoformat(price_as_of)
    profile = reference_profile() if vehicle_profile is None else vehicle_profile
    p, own = parameters(profile), "parameters" in profile
    car_source = profile.get("parameters_source_url") if own else NOTION_SOURCE
    values = [
        ("marginal_wheel_efficiency", p["marginal_wheel_efficiency"], "fraction", car_source),
        ("idle_rate", p["idle_rate"], "US-gal/hour", car_source), ("coast_deceleration", p["coast_deceleration"], "g", car_source),
        ("enrichment_start_fraction", p["enrichment_start_fraction"], "rated power fraction", car_source),
        ("enrichment_max", p["enrichment_max"], "fraction", car_source), ("drivetrain_factor", p["drivetrain_factor"], "fraction", car_source),
        ("fuel_energy", p["fuel_energy"], "J/US-gal" if own else "J/gasoline-equivalent US-gal", car_source),
        ("high_speed_reference", 65, "mph; comparison only", NOTION_SOURCE),
        ("road_conditions", "level, no wind, warm engine", None, NOTION_SOURCE),
        ("braking_fuel_cutoff", "zero fuel during both scenario decelerations; unobserved assumption", None, NOTION_SOURCE),
        ("event_context", "earlier anticipation and different arrival times may be infeasible in traffic", None, NOTION_SOURCE),
        ("endpoint_speed_tolerance", 2.0, "m/s", NOTION_SOURCE),
    ]
    assumptions = [{"key": key, "value": value, "unit": unit, "is_estimate": True,
                    "source_url": source, "as_of": "2026-10-24"} for key, value, unit, source in values]
    # The price is for the fuel the car burns: a diesel profile is priced in diesel.
    price_key = "diesel_price" if profile.get("fuel_type") == "diesel" else "gas_price"
    assumptions.append({"key": price_key, "value": float(price), "unit": "USD/US-gal",
                        "is_estimate": True, "source_url": price_source_url, "as_of": price_as_of})
    config = {"model_version": MODEL_VERSION, "vehicle_profile": profile,
              "fuel_price_usd_per_gal": float(price), "assumptions": assumptions}
    digest = hashlib.sha256(json.dumps(config, sort_keys=True, allow_nan=False).encode()).hexdigest()
    config["id"] = str(uuid5(NAMESPACE_URL, "drive-save:scoring-config:" + digest))
    return config


def _valid_vehicle(profile):
    """Another car's profile: the fields the model reads, with every parameter its own."""
    try:
        road, own = profile["road_load_si"], profile["parameters"]
        positive = [profile["mass_kg"], profile["rated_horsepower"], profile["city_mpg"], profile["highway_mpg"],
                    *(own[key] for key in DEFAULT_PARAMETERS if key != "enrichment_max")]
        numbers = [*positive, own["enrichment_max"], road["a_n"], road["b_n_per_mps"], road["c_n_per_mps2"]]
    except (KeyError, TypeError):
        return False
    return (set(own) == set(DEFAULT_PARAMETERS) and all(finite_number(n) for n in numbers)
            and all(n > 0 for n in positive) and own["enrichment_max"] >= 0 and own["enrichment_start_fraction"] < 1)


def _valid_config(profile, config):
    if not isinstance(profile, dict) or (profile != reference_profile() and not _valid_vehicle(profile)):
        raise TraceError("unsupported_vehicle_profile")
    if not isinstance(config, dict):
        raise TraceError("invalid_scoring_config")
    try:
        price = next(a for a in config["assumptions"] if a["key"] in ("gas_price", "diesel_price"))
        expected = scoring_config(config["fuel_price_usd_per_gal"], price_as_of=price["as_of"],
                                  price_source_url=price["source_url"], vehicle_profile=profile)
    except (KeyError, TypeError, ValueError, StopIteration) as exc:
        raise TraceError("invalid_scoring_config") from exc
    if config != expected:
        raise TraceError("scoring_config_mismatch")


def _events(events, trip, time, speed, profile, price):
    if not isinstance(events, list) or len(events) > 1000:
        raise TraceError("missing_or_invalid_events")
    if trip.get("events_complete") is not True:
        raise TraceError("event_recording_incomplete")
    version = trip.get("detector_version")
    if not isinstance(version, str) or not version.strip() or len(version) > 100:
        raise TraceError("missing_detector_version")
    receipts, intervals, seen = [], [], set()
    for event in events:
        if not isinstance(event, dict):
            raise TraceError("invalid_event")
        try:
            event_id = str(UUID(str(event["event_id"])))
        except (KeyError, ValueError, TypeError, AttributeError) as exc:
            raise TraceError("invalid_event_id") from exc
        if event_id in seen:
            raise TraceError("duplicate_event_id")
        seen.add(event_id)
        kind = event.get("type")
        if kind not in ("harsh_brake", "rapid_accel", "sharp_turn"):
            raise TraceError("invalid_event_type")
        if event.get("detector_version") != version:
            raise TraceError("event_detector_version_mismatch")
        duration, peak = event.get("duration_s"), event.get("peak_g")
        if not finite_number(duration) or not 0 < duration <= 120:
            raise TraceError("invalid_event_duration")
        if not finite_number(peak) or not 0 < peak <= 2:
            raise TraceError("invalid_event_peak")
        t0 = timestamp(event.get("ts")) - timestamp(trip["started_at"])
        t1 = t0 + duration
        if t0 < 0 or t1 > time[-1]:
            raise TraceError("event_outside_trip")
        endpoints = [event.get("speed_before_mph"), event.get("speed_after_mph")]
        if any(not finite_number(v) or not 0 <= v <= 120 for v in endpoints):
            raise TraceError("missing_or_invalid_event_speed")
        v1, v2 = (v * MPH_TO_MPS for v in endpoints)
        if max(abs(v1 - float(np.interp(t0, time, speed))), abs(v2 - float(np.interp(t1, time, speed)))) > 2:
            raise TraceError("event_speed_disagrees_with_trace")
        if kind != "sharp_turn" and abs(v2-v1) / duration > peak * G + 0.2:
            raise TraceError("event_peak_inconsistent_with_speed")
        if kind == "harsh_brake":
            if v1 <= v2:
                raise TraceError("brake_speed_direction_invalid")
            detail = brake_scenario(v1, v2, duration, profile)
            support_start = t0 - detail["preceding_seconds"]
            if support_start < -1e-6:
                raise TraceError("missing_braking_comparison_history")
            support_start = max(0.0, support_start)
            context_times = np.r_[support_start, time[(time > support_start) & (time < t0)], t0]
            if np.max(np.abs(np.interp(context_times, time, speed) - v1)) > 2:
                raise TraceError("braking_cruise_scenario_unsupported")
        elif kind == "rapid_accel":
            if v2 <= v1:
                raise TraceError("acceleration_speed_direction_invalid")
            detail = acceleration_scenario(v1, v2, duration, peak, profile)
            support_start = t0
        else:
            # Outside monetary scope, NOT a claim that cornering has zero real cost.
            detail = {"fuel_gal": 0.0, "monetary_scope": "coaching_only"}
            support_start = t0
        intervals.append((support_start, t1))
        receipts.append({"event_id": event_id, "type": kind, "duration_s": duration,
                         "support_start_s": support_start, "support_end_s": t1,
                         "cost_usd": detail["fuel_gal"] * price, **detail})
    intervals.sort()
    if any(right > following + 1e-6 for (_, right), (following, _) in zip(intervals, intervals[1:])):
        raise TraceError("overlapping_event_comparisons")
    return receipts, intervals


def estimate_trip(vehicle_profile, speed_samples, trip_metadata, scoring_config, events=None):
    """Recorded phone inputs are supported; all monetary results remain demo-only.

    An explicitly empty events list means detection completed with no events.
    Omission or an incomplete detector session never means zero avoidable fuel.
    """
    result = {"status": "insufficient_data", "fuel_gal": None, "reference_fuel_gal": None,
              "avoidable_usd": None, "estimated_trip_cost_usd": None, "quality_flags": [], "is_demo": True,
              "model_details": {"model_version": MODEL_VERSION, "estimate_kind": "experimental_math_model",
                                "validation_status": "laboratory_validation_pending",
                                "real_world_accuracy": "unverified", "comparison_validation_status": "unverified_counterfactual"}}
    try:
        _valid_config(vehicle_profile, scoring_config)
        if not isinstance(trip_metadata, dict) or trip_metadata.get("is_demo") is not True:
            raise TraceError("experimental_model_requires_demo_mode")
        if trip_metadata.get("source") not in ("recorded", "replayed", "synthetic"):
            raise TraceError("invalid_trip_source")
        time, speed, diagnostics = prepare_trace(speed_samples, trip_metadata)
        result["model_details"]["trace"] = diagnostics
        price = scoring_config["fuel_price_usd_per_gal"]
        receipts, excluded = _events(events, trip_metadata, time, speed, vehicle_profile, price)
        high = high_speed_scenario(time, speed, excluded, vehicle_profile)
        high["cost_usd"] = high["fuel_gal"] * price
        breakdown = {kind: sum(e["cost_usd"] for e in receipts if e["type"] == kind)
                     for kind in ("harsh_brake", "rapid_accel")}
        breakdown["high_speed"] = high["cost_usd"]
        avoidable = sum(breakdown.values())
        distance = diagnostics["integrated_distance_mi"]
        average_mph = distance / (float(time[-1]) / 3600)
        weight = min(1.0, max(0.0, (48.3 - average_mph) / (48.3 - 21.2)))
        # Budget estimate only: no fabricated measured total or subtracted "twin" total.
        fuel = distance * (weight / vehicle_profile["city_mpg"] + (1-weight) / vehicle_profile["highway_mpg"])
        result.update(status="scored", fuel_gal=fuel, avoidable_usd=avoidable, estimated_trip_cost_usd=fuel*price,
                      quality_flags=["experimental_estimate", "flat_road_warm_engine_assumed",
                                     "traffic_feasibility_unverified", "fuel_cutoff_assumed", "lab_and_event_accuracy_unverified"])
        result["model_details"].update({"scoring_config_id": scoring_config["id"],
            "vehicle_profile": vehicle_profile, "assumptions": scoring_config["assumptions"],
            "fuel_gal_basis": "approximate_label_mpg_budget_not_measured_fuel",
            "trip_budget_city_weight": weight, "estimated_trip_cost_usd": fuel * price,
            "events": receipts, "high_speed": high, "cost_breakdown_usd": breakdown,
            "avoidable_usd": avoidable, "events_complete": True,
            "detector_version": trip_metadata["detector_version"],
            "receipt_label": "Estimated fuel savings; accuracy not yet validated",
            "comparison_label": "Fuel difference under assumed earlier-coasting, enrichment, and 65 mph scenarios"})
    except TraceError as exc:
        result["quality_flags"] = [str(exc)]
    return result
