"""Contract tests: every endpoint answers with the agreed shapes and error format."""

import copy
import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

import store
from main import app

SAMPLE_TRIP = json.loads((Path(__file__).resolve().parents[2] / "fixtures" / "sample-trip.json").read_text())


@pytest.fixture(autouse=True)
def clean_store():
    store.reset()
    yield
    store.reset()


@pytest.fixture
def client():
    return TestClient(app)


def new_user(client, nickname="alex"):
    res = client.post("/users", json={"nickname": nickname})
    assert res.status_code == 201
    body = res.json()
    return body["user_id"], {"Authorization": f"Bearer {body['token']}"}


def upload(client, headers, trip=None):
    return client.post("/trips", json=trip or SAMPLE_TRIP, headers=headers)


def test_health(client):
    res = client.get("/health")
    assert res.status_code == 200
    assert res.json()["status"] == "ok"


def test_missing_token_uses_error_format(client):
    res = client.get("/leaderboard")
    assert res.status_code == 401
    assert res.json() == {"error": {"code": "unauthorized", "message": "Missing bearer token"}}


def test_invalid_token_is_rejected(client):
    res = client.get("/leaderboard", headers={"Authorization": "Bearer nope"})
    assert res.status_code == 401
    assert res.json()["error"]["code"] == "unauthorized"


def test_upload_sample_trip_and_read_receipt(client):
    _, headers = new_user(client)
    res = upload(client, headers)
    assert res.status_code == 201
    created = res.json()
    assert created["duplicate"] is False

    receipt = client.get(created["receipt_url"], headers=headers).json()
    assert receipt["trip_id"] == created["trip_id"]
    assert receipt["is_estimate"] is True
    assert receipt["cost_model"] == "flat_per_event"
    # Placeholder pricing: every harsh event costs $1.
    assert [e["cost_usd"] for e in receipt["events"]] == [1.0] * len(SAMPLE_TRIP["events"])
    assert receipt["avoidable_cost_usd"] == len(SAMPLE_TRIP["events"])
    per_event = next(a for a in receipt["assumptions"] if a["key"] == "cost_per_event")
    assert per_event["value"] == 1.0
    assert per_event["is_estimate"] is True


def test_trip_without_events_costs_nothing(client):
    _, headers = new_user(client)
    trip = copy.deepcopy(SAMPLE_TRIP)
    trip["events"] = []
    trip_id = upload(client, headers, trip).json()["trip_id"]
    receipt = client.get(f"/trips/{trip_id}/receipt", headers=headers).json()
    assert receipt["events"] == []
    assert receipt["avoidable_cost_usd"] == 0


def test_retried_upload_returns_same_trip(client):
    _, headers = new_user(client)
    first = upload(client, headers).json()
    retry = upload(client, headers)
    assert retry.status_code == 200
    assert retry.json()["trip_id"] == first["trip_id"]
    assert retry.json()["duplicate"] is True


def test_event_outside_trip_is_rejected(client):
    _, headers = new_user(client)
    trip = copy.deepcopy(SAMPLE_TRIP)
    trip["events"][0]["ts"] = "2026-10-24T21:00:00Z"
    res = upload(client, headers, trip)
    assert res.status_code == 422
    assert res.json()["error"]["code"] == "validation_error"


def test_receipt_is_owner_only(client):
    _, owner = new_user(client, "owner")
    _, other = new_user(client, "other")
    trip_id = upload(client, owner).json()["trip_id"]
    res = client.get(f"/trips/{trip_id}/receipt", headers=other)
    assert res.status_code == 403
    assert res.json()["error"]["code"] == "forbidden"


def test_crew_becomes_active_at_four_members(client):
    _, creator = new_user(client, "creator")
    crew = client.post("/crews", json={"name": "East Halls"}, headers=creator).json()
    assert crew["member_count"] == 1 and crew["active"] is False

    for name in ["b", "c", "d"]:
        _, headers = new_user(client, name)
        crew = client.post(f"/crews/{crew['crew_id']}/join", json={"join_code": crew["join_code"]}, headers=headers).json()

    assert crew["member_count"] == 4
    assert crew["active"] is True


def test_wrong_join_code_is_rejected(client):
    _, creator = new_user(client, "creator")
    crew = client.post("/crews", json={"name": "East Halls"}, headers=creator).json()
    _, outsider = new_user(client, "outsider")
    res = client.post(f"/crews/{crew['crew_id']}/join", json={"join_code": "WRONG1"}, headers=outsider)
    assert res.status_code == 403
    assert res.json()["error"]["code"] == "wrong_join_code"
    # Non-members never see the join code.
    assert client.get(f"/crews/{crew['crew_id']}", headers=outsider).json()["join_code"] is None


def test_leaderboard_ranks_active_crews_with_demo_crews(client):
    _, creator = new_user(client, "creator")
    crew = client.post("/crews", json={"name": "Real Crew"}, headers=creator).json()
    board = client.get("/leaderboard", headers=creator).json()
    assert all(s["is_demo"] for s in board["standings"])  # 1-member crew is not ranked yet

    for name in ["b", "c", "d"]:
        _, headers = new_user(client, name)
        client.post(f"/crews/{crew['crew_id']}/join", json={"join_code": crew["join_code"]}, headers=headers)

    board = client.get("/leaderboard?scope=crews", headers=creator).json()
    names = [s["name"] for s in board["standings"]]
    assert "Real Crew" in names
    assert [s["rank"] for s in board["standings"]] == list(range(1, len(names) + 1))


def test_member_leaderboard_needs_crew_id(client):
    _, headers = new_user(client)
    res = client.get("/leaderboard?scope=members", headers=headers)
    assert res.status_code == 400
    assert res.json()["error"]["code"] == "crew_id_required"


def test_progress_sets_baseline_after_three_trips(client):
    user_id, headers = new_user(client)
    for i in range(4):
        trip = copy.deepcopy(SAMPLE_TRIP)
        trip["client_trip_id"] = f"6f1c2a9e-4b7d-4c1e-9a3f-2d8e5b7c1a4{i}"
        if i == 3:
            trip["events"] = trip["events"][:1]  # a smoother fourth trip
        upload(client, headers, trip)

    progress = client.get(f"/users/{user_id}/progress", headers=headers).json()
    assert progress["trips_counted"] == 4
    assert progress["baseline_trips_needed"] == 0
    # Baseline: 9 events over 19.2 mi. Fourth trip: 1 event over 6.4 mi, where the baseline rate predicts 3.
    assert progress["improvement_pct"] == 66.7
    assert progress["est_savings_usd"] == 2.0


def test_vehicle_mpg_is_optional(client):
    _, headers = new_user(client)
    car = {"year": 2020, "make": "Honda", "model": "Civic"}
    res = client.put("/users/me/vehicle", json=car, headers=headers)
    assert res.status_code == 200
    assert res.json()["mpg_city"] is None
    assert res.json()["mpg_source"] is None

    res = client.put("/users/me/vehicle", json={**car, "mpg_city": 31, "mpg_hwy": 40}, headers=headers)
    assert res.json()["mpg_source"] == "manual"


def test_progress_is_self_only(client):
    _, headers = new_user(client, "a")
    other_id, _ = new_user(client, "b")
    assert client.get(f"/users/{other_id}/progress", headers=headers).status_code == 403
