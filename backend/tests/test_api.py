"""Contract tests: every endpoint answers with the agreed shapes and error format."""

import copy
import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

import store
from main import app
from services import cost_model

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures"
SAMPLE_TRIP = json.loads((FIXTURES / "sample-trip.json").read_text())
SAMPLE_VEHICLE = json.loads((FIXTURES / "sample-vehicle.json").read_text())


@pytest.fixture(autouse=True)
def clean_store():
    store.reset()
    yield
    store.reset()


@pytest.fixture
def client():
    return TestClient(app)


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


def test_driver_sends_their_car_and_gets_it_back_unchanged(client):
    _, headers = new_user(client)
    assert client.get("/users/me/vehicle", headers=headers).json()["error"]["code"] == "vehicle_not_set"
    saved = client.put("/users/me/vehicle", json=SAMPLE_VEHICLE, headers=headers)
    assert saved.status_code == 200
    assert saved.json() == SAMPLE_VEHICLE
    assert client.get("/users/me/vehicle", headers=headers).json() == SAMPLE_VEHICLE


@pytest.mark.parametrize(
    "body",
    [
        [],  # not an object
        "HONDA CIVIC",  # not an object
        {},  # no fields
        {f"field_{i}": i for i in range(201)},  # too many fields
    ],
)
def test_vehicle_data_must_be_a_reasonable_object(client, body):
    _, headers = new_user(client)
    res = client.put("/users/me/vehicle", json=body, headers=headers)
    assert res.status_code == 422
    assert res.json()["error"]["code"] == "validation_error"


def test_cost_model_receives_every_trip_event_and_vehicle_field(client, model_inputs):
    _, headers = new_user(client)
    # Any fields the app sends, including ones the backend has never heard of, must reach the model untouched.
    car = {**SAMPLE_VEHICLE, "trim": {"name": "Si", "tags": ["sport", "manual"]}, "is_hybrid": False, "notes": None}
    client.put("/users/me/vehicle", json=car, headers=headers)
    trip_id = upload(client, headers).json()["trip_id"]
    client.get(f"/trips/{trip_id}/receipt", headers=headers)

    inputs = model_inputs[-1]
    # The car: exactly what the app sent, with the same types.
    assert inputs.vehicle == car
    assert type(inputs.vehicle["equivalent_test_weight_lb"]) is int
    assert type(inputs.vehicle["target_coef_c_lbf_per_mph2"]) is float
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
        if field == "event_id":
            return str(value)
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
    # GPS speed readings: all of them for the trip, and 10 s before to 10 s after each event.
    assert len(inputs.trip.speed_samples) == len(SAMPLE_TRIP["speed_samples"])
    assert [s.sample_seq for s in brake.speed_samples] == list(range(21))
    assert [s.speed_mps for s in brake.speed_samples[9:14]] == [15.199, 15.199, 11.623, 8.494, 5.364]
    invalid = next(s for s in accel.speed_samples if s.sample_seq == 41)
    assert (invalid.speed_mps, invalid.speed_accuracy_mps) == (None, None)  # iOS sends -1 for an invalid reading
    assert all(e.speed_window_complete for e in inputs.events)
    # Fuel price: the US average.
    assert (inputs.fuel_price.key, inputs.fuel_price.value, inputs.fuel_price.unit) == ("fuel_price", 4.284, "USD/gal")


@pytest.mark.parametrize(
    "break_trip",
    [
        pytest.param(lambda t: t.update(speed_samples=[]), id="events-without-speed-samples"),
        pytest.param(lambda t: t["speed_samples"][0].update(ts="2026-10-24T19:00:00Z"), id="sample-outside-trip"),
        pytest.param(lambda t: t["speed_samples"][1].update(sample_seq=0), id="duplicate-sample-seq"),
        pytest.param(lambda t: t["events"][1].update(event_id=t["events"][0]["event_id"]), id="duplicate-event-id"),
        pytest.param(lambda t: t["events"][0].pop("detector_version"), id="missing-detector-version"),
        pytest.param(lambda t: t.update(source="replayed"), id="replay-not-marked-demo"),
    ],
)
def test_invalid_trip_uploads_are_rejected(client, break_trip):
    _, headers = new_user(client)
    trip = copy.deepcopy(SAMPLE_TRIP)
    break_trip(trip)
    res = upload(client, headers, trip)
    assert res.status_code == 422
    assert res.json()["error"]["code"] == "validation_error"


def test_nan_and_infinity_are_rejected(client):
    _, headers = new_user(client)
    json_headers = {**headers, "content-type": "application/json"}
    trip = json.dumps(SAMPLE_TRIP).replace('"distance_mi": 6.4', '"distance_mi": NaN')
    assert client.post("/trips", content=trip, headers=json_headers).status_code == 422
    car = '{"make": "HONDA", "equivalent_test_weight_lb": Infinity}'
    assert client.put("/users/me/vehicle", content=car, headers=json_headers).status_code == 422


def test_event_without_speeds_around_it_is_flagged_not_rejected(client, model_inputs):
    _, headers = new_user(client)
    trip = copy.deepcopy(SAMPLE_TRIP)
    trip["speed_samples"] = [s for s in trip["speed_samples"] if s["sample_seq"] >= 10]  # nothing before the brake
    res = upload(client, headers, trip)
    assert res.status_code == 201
    client.get(res.json()["receipt_url"], headers=headers)

    brake, accel, turn = model_inputs[-1].events
    assert brake.speed_window_complete is False
    assert accel.speed_window_complete and turn.speed_window_complete


def test_changed_trip_under_same_client_trip_id_conflicts(client):
    _, headers = new_user(client)
    upload(client, headers)

    changed = copy.deepcopy(SAMPLE_TRIP)
    changed["distance_mi"] = 7.0
    res = upload(client, headers, changed)
    assert res.status_code == 409
    assert res.json()["error"]["code"] == "trip_conflict"

    # The same trip written differently (other sample order, other time zone notation) is still a retry.
    same = copy.deepcopy(SAMPLE_TRIP)
    same["speed_samples"].reverse()
    same["started_at"] = "2026-10-24T16:01:00-04:00"
    assert upload(client, headers, same).status_code == 200


def test_driver_belongs_to_one_crew_at_a_time(client):
    _, alex = new_user(client, "alex")
    first = client.post("/crews", json={"name": "First"}, headers=alex).json()
    _, sam = new_user(client, "sam")
    second = client.post("/crews", json={"name": "Second"}, headers=sam).json()

    moved = client.post(f"/crews/{second['crew_id']}/join", json={"join_code": second["join_code"]}, headers=alex).json()
    assert moved["member_count"] == 2
    assert client.get(f"/crews/{first['crew_id']}", headers=alex).json()["member_count"] == 0


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


def test_receipt_keeps_the_car_from_upload_time(client):
    _, headers = new_user(client)
    client.put("/users/me/vehicle", json=SAMPLE_VEHICLE, headers=headers)
    trip_id = upload(client, headers).json()["trip_id"]
    client.put("/users/me/vehicle", json={"make": "TOYOTA", "model": "PRIUS"}, headers=headers)  # switch cars afterwards

    cost_input = client.get(f"/trips/{trip_id}/cost-input", headers=headers).json()
    assert cost_input["vehicle"] == SAMPLE_VEHICLE


def test_cost_input_endpoint_matches_model_input_and_is_owner_only(client, model_inputs):
    _, owner = new_user(client, "owner")
    _, other = new_user(client, "other")
    client.put("/users/me/vehicle", json=SAMPLE_VEHICLE, headers=owner)
    trip_id = upload(client, owner).json()["trip_id"]
    client.get(f"/trips/{trip_id}/receipt", headers=owner)

    shown = client.get(f"/trips/{trip_id}/cost-input", headers=owner).json()
    assert shown == model_inputs[-1].model_dump(mode="json")
    assert client.get(f"/trips/{trip_id}/cost-input", headers=other).status_code == 403


def test_progress_is_self_only(client):
    _, headers = new_user(client, "a")
    other_id, _ = new_user(client, "b")
    assert client.get(f"/users/{other_id}/progress", headers=headers).status_code == 403
