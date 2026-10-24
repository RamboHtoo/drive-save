"""Contract tests: every endpoint answers with the agreed shapes and error format."""

import copy
import json
from pathlib import Path
from urllib.error import URLError

import pytest
from fastapi.testclient import TestClient

import store
from main import app
from services import cost_model, fueleconomy

SAMPLE_TRIP = json.loads((Path(__file__).resolve().parents[2] / "fixtures" / "sample-trip.json").read_text())
DATA = Path(__file__).resolve().parent / "data"

# Recorded fueleconomy.gov responses, keyed by (path, sorted query params).
FAKE_FUELECONOMY = {
    ("menu/year", ()): {"menuItem": [{"text": "2021", "value": "2021"}, {"text": "2020", "value": "2020"}]},
    ("menu/make", (("year", 2020),)): {"menuItem": [{"text": "Honda", "value": "Honda"}, {"text": "Toyota", "value": "Toyota"}]},
    ("menu/model", (("make", "Honda"), ("year", 2020))): {
        "menuItem": [{"text": "Civic 4Dr", "value": "Civic 4Dr"}, {"text": "Clarity FCV", "value": "Clarity FCV"}]
    },
    ("menu/options", (("make", "Honda"), ("model", "Civic 4Dr"), ("year", 2020))): {
        "menuItem": [
            {"text": "Auto (variable gear ratios), 4 cyl, 1.5 L, Turbo", "value": "42150"},
            {"text": "Man 6-spd, 4 cyl, 2.0 L", "value": "42151"},
        ]
    },
    # A model with a single option comes back as an object, not a list.
    ("menu/options", (("make", "Honda"), ("model", "Clarity FCV"), ("year", 2020))): {"menuItem": {"text": "Auto (A1)", "value": "47535"}},
    ("42150", ()): json.loads((DATA / "fueleconomy-42150.json").read_text()),
    ("47535", ()): json.loads((DATA / "fueleconomy-47535.json").read_text()),
}


@pytest.fixture(autouse=True)
def clean_store():
    store.reset()
    yield
    store.reset()


@pytest.fixture
def client():
    return TestClient(app)


@pytest.fixture
def fake_fueleconomy(monkeypatch):
    async def fake_get(path, **params):
        return FAKE_FUELECONOMY.get((path, tuple(sorted(params.items()))))

    monkeypatch.setattr(fueleconomy, "_get", fake_get)


@pytest.fixture
def model_inputs(monkeypatch):
    """Records every CostModelInput handed to the cost model."""
    seen = []
    real_estimate = cost_model.estimate

    def spy(inputs):
        seen.append(inputs)
        return real_estimate(inputs)

    monkeypatch.setattr(cost_model, "estimate", spy)
    return seen


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


def test_car_picker_walks_year_make_model_option(client, fake_fueleconomy):
    _, headers = new_user(client)
    assert client.get("/vehicles/years", headers=headers).json() == [2021, 2020]
    assert client.get("/vehicles/makes?year=2020", headers=headers).json() == ["Honda", "Toyota"]
    assert client.get("/vehicles/models?year=2020&make=Honda", headers=headers).json() == ["Civic 4Dr", "Clarity FCV"]
    assert client.get("/vehicles/models?year=2020&make=NoSuchMake", headers=headers).json() == []

    civic = client.get("/vehicles/options", params={"year": 2020, "make": "Honda", "model": "Civic 4Dr"}, headers=headers).json()
    assert civic[0] == {"vehicle_id": 42150, "description": "Auto (variable gear ratios), 4 cyl, 1.5 L, Turbo"}
    single = client.get("/vehicles/options", params={"year": 2020, "make": "Honda", "model": "Clarity FCV"}, headers=headers).json()
    assert single == [{"vehicle_id": 47535, "description": "Auto (A1)"}]


def test_vehicle_specs_come_from_fueleconomy(client, fake_fueleconomy):
    _, headers = new_user(client)
    civic = client.get("/vehicles/42150", headers=headers).json()
    assert (civic["year"], civic["make"], civic["model"]) == (2020, "Honda", "Civic 4Dr")
    assert (civic["mpg_city"], civic["mpg_hwy"], civic["mpg_combined"]) == (32, 42, 36)
    assert civic["fuel_type"] == "Regular Gasoline"
    assert civic["powertrain"] is None
    assert (civic["cylinders"], civic["engine_displacement_l"]) == (4, 1.5)
    assert civic["kwh_per_100mi"] is None
    assert civic["weight_lb"] is None  # fueleconomy.gov has no weight data

    fuel_cell = client.get("/vehicles/47535", headers=headers).json()
    assert fuel_cell["powertrain"] == "FCV"
    assert (fuel_cell["cylinders"], fuel_cell["engine_displacement_l"]) == (None, None)

    missing = client.get("/vehicles/1", headers=headers)
    assert missing.status_code == 404
    assert missing.json()["error"]["code"] == "vehicle_not_found"


def test_driver_selects_a_car(client, fake_fueleconomy):
    _, headers = new_user(client)
    assert client.get("/users/me/vehicle", headers=headers).json()["error"]["code"] == "vehicle_not_set"
    selected = client.put("/users/me/vehicle", json={"vehicle_id": 42150}, headers=headers)
    assert selected.status_code == 200
    assert client.get("/users/me/vehicle", headers=headers).json() == selected.json()


def test_fueleconomy_outage_returns_502(client, monkeypatch):
    def unreachable(url):
        raise URLError("offline")

    monkeypatch.setattr(fueleconomy, "_fetch", unreachable)
    monkeypatch.setattr(fueleconomy, "_cache", {})
    _, headers = new_user(client)
    res = client.get("/vehicles/makes?year=2019", headers=headers)
    assert res.status_code == 502
    assert res.json()["error"]["code"] == "vehicle_data_unavailable"


def test_cost_model_receives_every_trip_event_and_vehicle_field(client, fake_fueleconomy, model_inputs):
    _, headers = new_user(client)
    client.put("/users/me/vehicle", json={"vehicle_id": 42150}, headers=headers)
    trip_id = upload(client, headers).json()["trip_id"]
    client.get(f"/trips/{trip_id}/receipt", headers=headers)

    inputs = model_inputs[-1]
    # The car: everything fueleconomy.gov returned for the selected vehicle.
    assert inputs.vehicle.model_dump(mode="json") == client.get("/vehicles/42150", headers=headers).json()
    # The trip.
    assert str(inputs.trip.trip_id) == trip_id
    assert inputs.trip.distance_mi == SAMPLE_TRIP["distance_mi"]
    assert inputs.trip.avg_speed_mph == SAMPLE_TRIP["avg_speed_mph"]
    assert inputs.trip.duration_s == 18 * 60
    # Every field the phone sent, for every event, in order.
    assert len(inputs.events) == len(SAMPLE_TRIP["events"])
    def as_sent(field, value):
        if field == "ts":
            return value.isoformat().replace("+00:00", "Z")
        if field == "speed_trace":
            return [sample.model_dump() for sample in value]
        return value

    for index, (sent, received) in enumerate(zip(SAMPLE_TRIP["events"], inputs.events)):
        assert received.index == index
        for field, value in sent.items():
            assert as_sent(field, getattr(received, field)) == value, field
    # Derived values: speed change, speed during the event, mean acceleration.
    brake, accel, turn = inputs.events
    assert brake.speed_change_mph == -22.0
    assert brake.mean_accel_g == pytest.approx(-22 * 0.44704 / 3.0 / 9.80665, abs=1e-4)
    assert accel.speed_change_mph == 19.0
    assert accel.mean_accel_g > 0
    assert turn.avg_speed_mph == 21.0
    assert turn.heading_change_deg == 85.0
    # The speed trace around each event: 10 s before to 10 s after.
    assert [(s.t_s, s.speed_mph) for s in brake.speed_trace[9:14]] == [(-1, 34.0), (0, 34.0), (1, 26.0), (2, 19.0), (3, 12.0)]
    assert all(len(e.speed_trace) == 21 for e in inputs.events)


@pytest.mark.parametrize(
    "trace",
    [
        None,  # missing
        [{"t_s": 1, "speed_mph": 20}, {"t_s": 2, "speed_mph": 21}],  # nothing from before the event
        [{"t_s": -2, "speed_mph": 20}, {"t_s": -1, "speed_mph": 21}],  # nothing from after the event
        [{"t_s": 1, "speed_mph": 20}, {"t_s": -1, "speed_mph": 21}],  # times out of order
        [{"t_s": -1, "speed_mph": 20}],  # a single sample
    ],
)
def test_speed_trace_is_required_and_must_surround_the_event(client, trace):
    _, headers = new_user(client)
    trip = copy.deepcopy(SAMPLE_TRIP)
    if trace is None:
        del trip["events"][0]["speed_trace"]
    else:
        trip["events"][0]["speed_trace"] = trace
    res = upload(client, headers, trip)
    assert res.status_code == 422
    assert res.json()["error"]["code"] == "validation_error"


def test_cost_model_input_without_car_or_optional_fields(client, model_inputs):
    _, headers = new_user(client)
    trip = copy.deepcopy(SAMPLE_TRIP)
    for event in trip["events"]:
        event.pop("duration_s", None)
        event.pop("heading_change_deg", None)
    trip_id = upload(client, headers, trip).json()["trip_id"]
    receipt = client.get(f"/trips/{trip_id}/receipt", headers=headers).json()

    inputs = model_inputs[-1]
    assert inputs.vehicle is None
    assert all(e.duration_s is None and e.mean_accel_g is None and e.heading_change_deg is None for e in inputs.events)
    assert receipt["avoidable_cost_usd"] == len(trip["events"])  # the placeholder still prices every event


def test_receipt_keeps_the_car_from_upload_time(client, fake_fueleconomy):
    _, headers = new_user(client)
    client.put("/users/me/vehicle", json={"vehicle_id": 42150}, headers=headers)
    trip_id = upload(client, headers).json()["trip_id"]
    client.put("/users/me/vehicle", json={"vehicle_id": 47535}, headers=headers)  # switch cars afterwards

    cost_input = client.get(f"/trips/{trip_id}/cost-input", headers=headers).json()
    assert cost_input["vehicle"]["vehicle_id"] == 42150


def test_cost_input_endpoint_matches_model_input_and_is_owner_only(client, fake_fueleconomy, model_inputs):
    _, owner = new_user(client, "owner")
    _, other = new_user(client, "other")
    client.put("/users/me/vehicle", json={"vehicle_id": 42150}, headers=owner)
    trip_id = upload(client, owner).json()["trip_id"]
    client.get(f"/trips/{trip_id}/receipt", headers=owner)

    shown = client.get(f"/trips/{trip_id}/cost-input", headers=owner).json()
    assert shown == model_inputs[-1].model_dump(mode="json")
    assert client.get(f"/trips/{trip_id}/cost-input", headers=other).status_code == 403


def test_progress_is_self_only(client):
    _, headers = new_user(client, "a")
    other_id, _ = new_user(client, "b")
    assert client.get(f"/users/{other_id}/progress", headers=headers).status_code == 403
