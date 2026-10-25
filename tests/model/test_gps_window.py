"""Asynchronous observation windows, without extrapolation or hidden coverage loss."""
from copy import deepcopy
from datetime import datetime, timedelta

import numpy as np
import pytest

from drive_save_model import estimate_trip
from drive_save_model.physics import MPH_TO_MPS, brake_scenario
from drive_save_model.trace import prepare_trace
from drive_save_model.validation import cruise_payload, example_payload, payload_from_trace


def shifted(value, seconds):
    return (datetime.fromisoformat(value) + timedelta(seconds=seconds)).isoformat()


def assert_rejected(payload, reason):
    result = estimate_trip(**payload)
    assert result["status"] == "insufficient_data"
    assert result["quality_flags"] == [reason]
    assert all(result[k] is None for k in ("fuel_gal", "avoidable_usd", "estimated_trip_cost_usd"))
    assert "events" not in result["model_details"]


def test_button_times_do_not_change_observed_costs_or_event_alignment():
    payload = example_payload()
    expected = estimate_trip(**payload)
    payload["trip_metadata"]["started_at"] = shifted(payload["trip_metadata"]["started_at"], -.1)
    payload["trip_metadata"]["ended_at"] = shifted(payload["trip_metadata"]["ended_at"], .2)
    untouched = deepcopy(payload)
    result = estimate_trip(**payload)
    assert payload == untouched
    assert result["status"] == "scored"
    for field in ("fuel_gal", "avoidable_usd", "estimated_trip_cost_usd"):
        assert result[field] == pytest.approx(expected[field], rel=1e-6)
    trace = result["model_details"]["trace"]
    assert trace["scoring_start_s"] == pytest.approx(.1, abs=1e-6)
    assert trace["unobserved_end_seconds"] == pytest.approx(.2, abs=1e-6)
    assert trace["scoring_duration_seconds"] == pytest.approx(300)
    assert trace["direct_time_coverage"] == pytest.approx(300 / 300.3)
    assert "gps_window_trimmed" in result["quality_flags"]
    assert "GPS-covered portion only" in result["model_details"]["receipt_label"]


@pytest.mark.parametrize("side", ["start", "end"])
@pytest.mark.parametrize("gap,accepted", [(0.000002, True), (.1, True), (3., True), (3.00001, False)])
def test_edge_gap_limits(side, gap, accepted):
    payload = cruise_payload()
    key = "started_at" if side == "start" else "ended_at"
    payload["trip_metadata"][key] = shifted(payload["trip_metadata"][key], -gap if side == "start" else gap)
    result = estimate_trip(**payload)
    if accepted:
        assert result["status"] == "scored"
    else:
        assert_rejected(payload, "gps_boundary_gap_over_three_seconds")


def test_both_edges_have_individual_limits_and_are_not_extrapolated():
    payload = cruise_payload()
    del payload["speed_samples"][-3:]
    del payload["speed_samples"][:3]
    time, speed, trace = prepare_trace(payload["speed_samples"], payload["trip_metadata"])
    assert time[0] == 3 and time[-1] == 297
    assert trace["integrated_distance_mi"] == pytest.approx(75 * 294 / 3600)
    assert trace["direct_time_coverage"] == pytest.approx(294 / 300)
    result = estimate_trip(**payload)
    assert result["status"] == "scored"
    assert result["model_details"]["high_speed"]["priced_distance_m"] == pytest.approx(75 * MPH_TO_MPS * 294)
    assert result["model_details"]["scored_distance_mi"] == round(trace["integrated_distance_mi"], 6)


@pytest.mark.parametrize("bad", [None, -1., 2.00001])
def test_invalid_edge_accuracy_is_skipped_without_inventing_a_reading(bad):
    payload = cruise_payload()
    payload["speed_samples"][0]["speed_accuracy_mps"] = bad
    payload["speed_samples"][-1]["speed_accuracy_mps"] = bad
    result = estimate_trip(**payload)
    assert result["status"] == "scored"
    assert result["model_details"]["trace"]["scoring_duration_seconds"] == 298


@pytest.mark.parametrize("missing,accepted", [(13, True), (14, False)])
def test_coverage_counts_unobserved_edges_against_original_session(missing, accepted):
    payload = cruise_payload()
    payload["speed_samples"] = payload["speed_samples"][1:-1]
    for i in range(10, 10 + missing * 10, 10):
        payload["speed_samples"][i]["speed_mps"] = None
    if accepted:
        result = estimate_trip(**payload)
        assert result["status"] == "scored"
        assert result["model_details"]["trace"]["direct_time_coverage"] == pytest.approx(.95)
    else:
        assert_rejected(payload, "valid_time_coverage_below_95_percent")


def test_fractional_samples_preserve_knots_distance_and_delivery_order():
    seconds = np.r_[0.17, np.arange(1., 61.) + .17, 60.8]
    speed = 15 + .5 * np.sin(seconds)
    payload = payload_from_trace(seconds, speed)
    payload["trip_metadata"]["ended_at"] = shifted(payload["trip_metadata"]["ended_at"], .2)
    payload["speed_samples"].reverse()  # Batched delivery need not be sorted.
    grid, _, trace = prepare_trace(payload["speed_samples"], payload["trip_metadata"])
    assert grid[0] == pytest.approx(.17, abs=1e-6)
    assert grid[-1] == pytest.approx(60.8, abs=1e-6)
    assert trace["integrated_distance_mi"] == pytest.approx(payload["trip_metadata"]["distance_mi"], abs=1e-8)
    assert estimate_trip(**payload)["status"] == "scored"


@pytest.mark.parametrize("side", ["start", "end"])
def test_event_outside_observed_window_is_not_dropped_or_extrapolated(side):
    payload = cruise_payload(34)
    payload["speed_samples"] = payload["speed_samples"][1:-1]
    event = deepcopy(example_payload()["events"][2])
    event.update(ts=shifted(payload["trip_metadata"]["started_at"], .5 if side == "start" else 298.5),
                 duration_s=1, speed_before_mph=34, speed_after_mph=34)
    payload["events"] = [event]
    assert_rejected(payload, "event_outside_scoring_window")


def test_braking_comparison_must_fit_inside_observed_window():
    template = example_payload()
    event = deepcopy(template["events"][0])
    prior = brake_scenario(34 * MPH_TO_MPS, 12 * MPH_TO_MPS, 3, template["vehicle_profile"])["preceding_seconds"]
    event_start = prior + .5
    time = np.unique(np.r_[np.arange(301.), event_start, event_start + 3])
    speed = np.interp(time, [0, event_start, event_start + 3, 300], np.array([34, 34, 12, 12]) * MPH_TO_MPS)
    payload = payload_from_trace(time, speed)
    event["ts"] = shifted(payload["trip_metadata"]["started_at"], event_start)
    payload["events"] = [event]
    assert estimate_trip(**payload)["status"] == "scored"
    payload["speed_samples"].pop(0)
    assert_rejected(payload, "missing_braking_comparison_history")


def test_trimming_does_not_hide_sparse_interior_or_short_recording():
    payload = cruise_payload()
    payload["speed_samples"] = payload["speed_samples"][1:-1]
    del payload["speed_samples"][50:53]
    assert_rejected(payload, "gps_gap_over_three_seconds")
    short = payload_from_trace(np.arange(5.), np.full(5, 10.))
    short["speed_samples"] = short["speed_samples"][1:-1]
    assert_rejected(short, "scoring_window_too_short")


def test_subsecond_speed_spike_cannot_disappear_during_resampling():
    payload = cruise_payload(30)
    sample = dict(payload["speed_samples"][0], sample_seq=999,
                  ts=shifted(payload["trip_metadata"]["started_at"], .1), speed_mps=40.)
    payload["speed_samples"].append(sample)
    assert_rejected(payload, "implausible_speed_change")


def test_boundary_fix_does_not_override_detector_completeness():
    payload = cruise_payload()
    payload["speed_samples"] = payload["speed_samples"][1:-1]
    payload["trip_metadata"]["events_complete"] = False
    assert_rejected(payload, "event_recording_incomplete")
