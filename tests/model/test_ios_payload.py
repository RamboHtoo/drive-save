"""The fixture is serialized by production Swift code, with synthetic inputs."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path

import pytest

from drive_save_model import reference_profile, scoring_config
from scripts.verify_ios_payload import verify

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures/ios"


def swift_payload():
    return json.loads((FIXTURES / "swift-async-replay.json").read_text())


def test_fixture_provenance_and_unmodified_builder_payload():
    raw = (FIXTURES / "swift-async-replay.json").read_bytes()
    provenance = json.loads((FIXTURES / "provenance.json").read_text())
    assert hashlib.sha256(raw).hexdigest() == provenance["payload_sha256"]
    assert provenance["real_device_recording"] is False
    assert hashlib.sha256((FIXTURES / "generate.swift").read_bytes()).hexdigest() == provenance["generator_sha256"]
    payload = json.loads(raw)
    assert payload["source"] == "replayed" and payload["is_demo"] is True
    assert "events_complete" not in payload and "detector_version" not in payload
    before = deepcopy(payload)
    report = verify(payload, reference_profile(), scoring_config(3.5, price_as_of="2026-10-25"))
    assert payload == before
    assert report["gps"]["status"] == "accepted"
    trace = report["gps"]["trace"]
    assert trace["scoring_start_s"] == .625
    assert trace["unobserved_end_seconds"] == .375
    assert trace["scoring_duration_seconds"] == 300
    assert trace["direct_time_coverage"] == pytest.approx(300 / 301)
    assert report["model"]["quality_flags"] == ["event_recording_incomplete"]
    assert report["model"]["avoidable_usd"] is None


def test_complete_synthetic_contract_prices_all_three_swift_events():
    payload = swift_payload()
    # This is an explicitly synthetic contract variant, NOT a claim that the
    # current app populates these fields, or that a device detector completed.
    payload.update(events_complete=True, detector_version="synthetic-ios-contract-v1")
    report = verify(payload, reference_profile(), scoring_config(3.5, price_as_of="2026-10-25"))
    result = report["model"]
    assert result["status"] == "scored"
    assert "gps_window_trimmed" in result["quality_flags"]
    details = result["model_details"]
    assert len(details["events"]) == 3
    assert result["avoidable_usd"] > 0
    assert result["avoidable_usd"] == pytest.approx(sum(details["cost_breakdown_usd"].values()))


def test_verifier_never_relabels_recorded_payload_or_fills_missing_metadata():
    payload = swift_payload()
    payload.update(source="recorded", is_demo=False)
    before = deepcopy(payload)
    report = verify(payload, reference_profile(), scoring_config(3.5, price_as_of="2026-10-25"))
    assert payload == before
    assert report["gps"]["status"] == "accepted"
    assert report["model"]["quality_flags"] == ["experimental_model_requires_demo_mode"]
