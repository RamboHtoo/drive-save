"""Contract tests: every endpoint answers with the agreed shapes and error format.

They run against a real TimescaleDB with the shared schema (see conftest.py).
"""

import copy
import json
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from conftest import query
from main import app
from services import cost_model

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures"
SAMPLE_TRIP = json.loads((FIXTURES / "sample-trip.json").read_text())
SAMPLE_VEHICLE = json.loads((FIXTURES / "sample-vehicle.json").read_text())


@pytest.fixture
def client():
    with TestClient(app) as c:  # runs the app's startup, which connects to the database
        yield c


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


def parse(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def fresh_trip(events=None):
    """The sample trip as a new trip that ended a minute ago (weekly standings only count this week).

    New client_trip_id and event ids; optionally only the first few events (brake, acceleration, turn).
    """
    trip = copy.deepcopy(SAMPLE_TRIP)
    trip["client_trip_id"] = str(uuid.uuid4())
    for event in trip["events"]:
        event["event_id"] = str(uuid.uuid4())
    if events is not None:
        trip["events"] = trip["events"][:events]

    shift = datetime.now(timezone.utc) - timedelta(minutes=1) - parse(trip["ended_at"])

    def move(ts):
        return (parse(ts) + shift).isoformat().replace("+00:00", "Z")

    trip["started_at"], trip["ended_at"] = move(trip["started_at"]), move(trip["ended_at"])
    for item in trip["events"] + trip["speed_samples"]:
        item["ts"] = move(item["ts"])
    return trip


def first_part(trip, seconds):
    """The first `seconds` of a trip as a trip of its own, with the distance its readings add up to."""
    start = parse(trip["started_at"])
    trip["speed_samples"] = [s for s in trip["speed_samples"] if (parse(s["ts"]) - start).total_seconds() <= seconds]
    trip["events"] = [e for e in trip["events"] if (parse(e["ts"]) - start).total_seconds() + e["duration_s"] <= seconds]
    trip["ended_at"] = trip["speed_samples"][-1]["ts"]
    valid = [((parse(s["ts"]) - start).total_seconds(), s["speed_mps"]) for s in trip["speed_samples"] if s["speed_mps"] >= 0]
    meters = sum((t1 - t0) * (v0 + v1) / 2 for (t0, v0), (t1, v1) in zip(valid, valid[1:]))
    trip["distance_mi"] = round(meters / 1609.344, 4)
    trip["avg_speed_mph"] = round(trip["distance_mi"] / (seconds / 3600), 1)
    return trip


def upload(client, headers, trip=None):
    return client.post("/trips", json=trip or SAMPLE_TRIP, headers=headers)


def trip_total(trip_id):
    """The model's unrounded avoidable cost for a stored trip."""
    return float(query("SELECT avoidable_usd FROM trips WHERE id = $1", uuid.UUID(trip_id))[0]["avoidable_usd"])


def test_health_reports_the_database(client):
    res = client.get("/health")
    assert res.status_code == 200
    assert res.json()["status"] == "ok"
    assert res.json()["database"] == "ok"
    assert res.json()["schema_version"] == 4


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
    assert (receipt["cost_model"], receipt["is_estimate"], receipt["is_demo"]) == ("vehicle-fuel-v1", True, True)
    assert receipt["label"] == "Estimated fuel savings; accuracy not yet validated"
    # The Mazda5 model prices braking and acceleration; sharp turns are coaching only. Time above 65 mph adds to the total.
    brake, accel, turn = (e["cost_usd"] for e in receipt["events"])
    assert brake > 0 and accel > 0 and turn == 0
    assert receipt["high_speed_cost_usd"] > 0
    assert receipt["avoidable_cost_usd"] == pytest.approx(brake + accel + turn + receipt["high_speed_cost_usd"], abs=2e-4)
    price = next(a for a in receipt["assumptions"] if a["key"] == "gas_price")
    assert (price["value"], price["source_url"]) == (4.284, cost_model.US_AVERAGE_FUEL_PRICE.source_url)
    assert any(note.startswith("road_conditions: ") for note in receipt["notes"])


def test_trip_without_events_only_pays_for_time_above_65_mph(client):
    _, headers = new_user(client)
    trip_id = upload(client, headers, fresh_trip(events=0)).json()["trip_id"]
    receipt = client.get(f"/trips/{trip_id}/receipt", headers=headers).json()
    assert receipt["events"] == []
    assert receipt["avoidable_cost_usd"] == receipt["high_speed_cost_usd"] > 0


@pytest.mark.parametrize(
    "change, reason",
    [
        pytest.param(lambda t: t.update(events_complete=False), "event_recording_incomplete", id="detector-stopped"),
        pytest.param(lambda t: t.pop("detector_version"), "missing_detector_version", id="no-trip-detector-version"),
        pytest.param(lambda t: t.update(speed_samples=t["speed_samples"][:150]), "missing_boundary_speed", id="readings-stop-early"),
        pytest.param(lambda t: [e.pop("duration_s") for e in t["events"]], "invalid_event_duration", id="no-event-duration"),
    ],
)
def test_trip_the_model_cannot_price_is_kept_without_a_receipt(client, change, reason):
    user_id, headers = new_user(client)
    trip = fresh_trip()
    change(trip)
    res = upload(client, headers, trip)
    assert res.status_code == 201
    receipt = client.get(res.json()["receipt_url"], headers=headers)
    assert receipt.status_code == 409
    assert receipt.json()["error"]["code"] == "trip_not_scored"
    assert reason in receipt.json()["error"]["message"]
    row = query("SELECT status, quality_flags, fuel_gal FROM trips WHERE user_id = $1", uuid.UUID(user_id))[0]
    assert (row["status"], json.loads(row["quality_flags"]), row["fuel_gal"]) == ("insufficient_data", [reason], None)
    assert query("SELECT count(*) AS n FROM trip_metrics")[0]["n"] == 0


def test_everything_is_demo_data_while_the_model_is_experimental(client):
    _, headers = new_user(client)
    crew = client.post("/crews", json={"name": "Roommates"}, headers=headers).json()
    assert crew["is_demo"] is True
    trip = fresh_trip()
    assert trip["is_demo"] is False  # what the app sends for a real drive
    created = upload(client, headers, trip).json()
    row = query("SELECT is_demo, source FROM trips WHERE id = $1", uuid.UUID(created["trip_id"]))[0]
    assert (row["is_demo"], row["source"]) == (True, "recorded")
    assert client.get(created["receipt_url"], headers=headers).json()["is_demo"] is True
    assert upload(client, headers, trip).json()["duplicate"] is True  # a retry still matches the stored trip
    assert client.get("/leaderboard", headers=headers).json()["is_demo"] is True


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


def test_leaderboard_ranks_members_inside_the_callers_crew(client):
    _, alex = new_user(client, "alex")
    crew = client.post("/crews", json={"name": "Roommates"}, headers=alex).json()
    members = {"alex": alex}
    for name in ["blake", "casey", "drew"]:
        _, headers = new_user(client, name)
        client.post(f"/crews/{crew['crew_id']}/join", json={"join_code": crew["join_code"]}, headers=headers)
        members[name] = headers

    # Alex and Blake drive a 3-trip baseline of the full sample trip, then the same route reporting fewer events:
    # Blake only the brake, Alex the brake and the acceleration. Turns cost nothing in this model.
    later = {}
    for name, later_events in [("alex", 2), ("blake", 1)]:
        for _ in range(3):
            full = upload(client, members[name], fresh_trip()).json()["trip_id"]
        later[name] = upload(client, members[name], fresh_trip(events=later_events)).json()["trip_id"]
    # Same distance every time, so improvement is the share of the full trip's cost a later trip avoided.
    saved = {name: trip_total(full) - trip_total(trip_id) for name, trip_id in later.items()}
    assert saved["blake"] > 0 and saved["alex"] == pytest.approx(0, abs=1e-6)

    board = client.get("/leaderboard", headers=members["drew"]).json()
    assert (board["crew_name"], board["member_count"], board["active"]) == ("Roommates", 4, True)
    assert [(s["nickname"], s["rank"], s["improvement_pct"]) for s in board["standings"]] == [
        ("blake", 1, round(100 * saved["blake"] / trip_total(full), 1)),
        ("alex", 2, 0.0),
        ("casey", None, None),  # no baseline yet: listed last, unranked
        ("drew", None, None),
    ]
    # The iOS app decodes est_savings_usd as a number, so unranked drivers get 0 rather than null.
    assert [(s["state"], s["est_savings_usd"], s["trips_counted"]) for s in board["standings"]] == [
        ("ready", round(saved["blake"], 4), 1),
        ("ready", 0.0, 1),
        ("collecting_baseline", 0.0, 0),
        ("collecting_baseline", 0.0, 0),
    ]


def test_leaderboard_needs_a_crew_and_turns_active_at_four(client):
    _, headers = new_user(client)
    res = client.get("/leaderboard", headers=headers)
    assert res.status_code == 404
    assert res.json()["error"]["code"] == "not_in_crew"

    client.post("/crews", json={"name": "Solo"}, headers=headers)
    board = client.get("/leaderboard", headers=headers).json()
    assert (board["member_count"], board["active"]) == (1, False)


def test_progress_sets_baseline_after_three_trips(client):
    user_id, headers = new_user(client)
    for _ in range(3):
        full = upload(client, headers, fresh_trip()).json()["trip_id"]
    assert client.get(f"/users/{user_id}/progress", headers=headers).json()["improvement_pct"] is None  # no later trip yet
    smoother = upload(client, headers, fresh_trip(events=1)).json()["trip_id"]  # same route, only the brake

    progress = client.get(f"/users/{user_id}/progress", headers=headers).json()
    assert progress["trips_counted"] == 4
    assert progress["baseline_trips_needed"] == 0
    saved = trip_total(full) - trip_total(smoother)
    assert progress["improvement_pct"] == round(100 * saved / trip_total(full), 1)
    assert progress["est_savings_usd"] == round(saved, 4)
    assert progress["weekly"][-1]["miles"] == round(4 * SAMPLE_TRIP["distance_mi"], 1)


def test_uploads_follow_the_database_rules(client):
    user_id, headers = new_user(client)
    short = first_part(fresh_trip(), seconds=100)  # under a mile: priced, but never a baseline trip
    assert short["distance_mi"] < 1
    upload(client, headers, short)
    for _ in range(3):
        upload(client, headers, fresh_trip())
    upload(client, headers, fresh_trip(events=1))

    trips = query(
        "SELECT id, status, baseline_slot, model_result->>'estimate_kind' AS kind FROM trips WHERE user_id = $1 ORDER BY accepted_seq",
        uuid.UUID(user_id),
    )
    assert [(t["status"], t["baseline_slot"]) for t in trips] == [("scored", None), ("scored", 1), ("scored", 2), ("scored", 3), ("scored", None)]
    assert {t["kind"] for t in trips} == {"experimental_math_model"}  # the model's full result is kept with each trip
    assert query("SELECT count(*) AS n FROM trip_metrics WHERE user_id = $1", uuid.UUID(user_id))[0]["n"] == 5
    assert query("SELECT count(*) AS n FROM speed_samples")[0]["n"] == 4 * len(SAMPLE_TRIP["speed_samples"]) + len(short["speed_samples"])
    # One immutable configuration, under the id the model derives from its contents.
    assert [str(r["id"]) for r in query("SELECT id FROM scoring_configs")] == [cost_model.SCORING_CONFIG["id"]]
    # Signed savings against the frozen baseline: the short trip came first, so only the last trip counts.
    ledger = query("SELECT amount_usd FROM savings_ledger WHERE user_id = $1", uuid.UUID(user_id))
    saved = trip_total(str(trips[1]["id"])) - trip_total(str(trips[4]["id"]))
    assert [float(r["amount_usd"]) for r in ledger] == [pytest.approx(saved, abs=1e-6)]


def test_trip_keeps_detector_coverage_and_its_league(client):
    _, headers = new_user(client)
    crew = client.post("/crews", json={"name": "Roommates"}, headers=headers).json()
    trip = fresh_trip()
    created = upload(client, headers, trip)
    assert created.status_code == 201
    row = query("SELECT events_complete, detector_version, league_id FROM trips WHERE id = $1", uuid.UUID(created.json()["trip_id"]))[0]
    assert (row["events_complete"], row["detector_version"], str(row["league_id"])) == (True, "ios-0.1.0", crew["crew_id"])
    assert upload(client, headers, trip).json()["duplicate"] is True  # both fields round-trip, so the retry matches
    assert upload(client, headers, {**trip, "events_complete": False}).status_code == 409

    # App builds that don't send the fields yet: not complete, version unknown.
    older = fresh_trip()
    del older["events_complete"], older["detector_version"]
    row = query("SELECT events_complete, detector_version FROM trips WHERE id = $1", uuid.UUID(upload(client, headers, older).json()["trip_id"]))[0]
    assert (row["events_complete"], row["detector_version"]) == (False, None)

    assert upload(client, headers, {**fresh_trip(), "detector_version": "   "}).status_code == 422


def test_data_survives_a_server_restart():
    with TestClient(app) as before:
        _, headers = new_user(before)
        trip_id = upload(before, headers).json()["trip_id"]
        receipt = before.get(f"/trips/{trip_id}/receipt", headers=headers).json()
    with TestClient(app) as after:  # the app shut down and started again; same database
        assert after.get(f"/trips/{trip_id}/receipt", headers=headers).json() == receipt


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


@pytest.fixture
def vehicle_list():
    """The vehicle list that scripts/load_vehicles.py loads from vehicle/ (test-db.sh runs it)."""
    if query("SELECT count(*) FROM vehicle_models")[0]["count"] == 0:
        pytest.skip("vehicle list not loaded: put the EPA files in vehicle/ and rerun backend/scripts/test-db.sh")


MAZDA5_2012 = {"make": "Mazda", "model": "MAZDA5", "year": 2012}


def test_car_picker_walks_brand_then_model_then_year(client, vehicle_list):
    makes = client.get("/vehicles/makes").json()["makes"]
    assert "Mazda" in makes and makes == sorted(makes, key=str.upper)

    models = client.get("/vehicles/models", params={"make": "mazda"}).json()  # case doesn't matter
    assert models["make"] == "Mazda" and "MAZDA5" in models["models"]

    years = client.get("/vehicles/years", params={"make": "Mazda", "model": "Mazda5"}).json()
    assert years["model"] == "MAZDA5" and 2012 in years["years"]
    assert years["years"] == sorted(years["years"], reverse=True)

    car = client.get("/vehicles/details", params=MAZDA5_2012).json()
    assert (car["make"], car["model"], car["year"], car["supported"]) == ("Mazda", "MAZDA5", 2012, True)
    assumptions = {a["key"] for a in cost_model.SCORING_CONFIG["assumptions"]}
    assert {p["key"] for p in car["parameters"]} <= assumptions  # named like the model's own assumptions
    assert {p["key"]: p["value"] for p in car["parameters"]}["idle_rate"] == 0.25  # 2.5 L, like the model's Mazda5


def test_model_names_with_slashes_work_as_query_parameters(client, vehicle_list):
    years = client.get("/vehicles/years", params={"make": "Honda", "model": "ACCORD EX/EX-L COUPE"})
    assert years.status_code == 200 and years.json()["years"]


@pytest.mark.parametrize(
    "query, model",
    [
        ("make=Lexus&model=RX%20450h%2B%20AWD", "RX 450h+ AWD"),  # everything percent-encoded
        ("make=Lexus&model=RX%20450h+%20AWD", "RX 450h+ AWD"),  # iOS URLComponents: spaces %20, plus left as it is
        ("make=Lexus&model=RX+450h%2B+AWD", "RX 450h+ AWD"),  # form encoding: spaces +, plus %2B
        ("make=Lexus&model=RX+450h+AWD", "RX 450h AWD"),  # form encoding of the plus-less model next to it
        ("make=Saab&model=FCH69+F46", "FCH69+F46"),  # iOS, no spaces to tell: the space reading finds nothing
    ],
)
def test_a_plus_sign_in_a_model_name_finds_that_car(client, vehicle_list, query, model):
    years = client.get(f"/vehicles/years?{query}")
    assert years.status_code == 200 and years.json()["model"] == model
    car = client.get(f"/vehicles/details?{query}&year={years.json()['years'][0]}")
    assert car.status_code == 200 and car.json()["model"] == model


@pytest.mark.parametrize(
    "path, params",
    [
        ("/vehicles/models", {"make": "Nope"}),
        ("/vehicles/years", {"make": "Mazda", "model": "Nope"}),
        ("/vehicles/details", {"make": "Mazda", "model": "MAZDA5", "year": 1999}),
    ],
)
def test_unknown_cars_are_not_found(client, vehicle_list, path, params):
    res = client.get(path, params=params)
    assert res.status_code == 404
    assert res.json()["error"]["code"] == "vehicle_not_found"


def test_car_picker_needs_its_query_parameters(client):
    res = client.get("/vehicles/years", params={"make": "Mazda"})
    assert res.status_code == 422
    assert res.json()["error"]["code"] == "validation_error"


def test_electric_cars_are_listed_without_fuel_model_parameters(client, vehicle_list):
    tesla = client.get("/vehicles/models", params={"make": "Tesla"}).json()["models"][0]
    year = client.get("/vehicles/years", params={"make": "Tesla", "model": tesla}).json()["years"][0]
    car = client.get("/vehicles/details", params={"make": "Tesla", "model": tesla, "year": year}).json()
    assert car["supported"] is False and car["parameters"] == []
    assert car["specs"]["fuel_type"] == "electricity"


def test_sign_up_with_a_car_stores_it(client, vehicle_list):
    res = client.post("/users", json={"nickname": "kai", "vehicle": {"make": "MAZDA", "model": "mazda5", "year": 2012}})
    assert res.status_code == 201
    car = res.json()["vehicle"]
    assert car == client.get("/vehicles/details", params=MAZDA5_2012).json()

    headers = {"Authorization": f"Bearer {res.json()['token']}"}
    assert client.get("/users/me/vehicle", headers=headers).json() == car
    stored = query("SELECT mpg_city, mpg_hwy FROM users WHERE id = $1", uuid.UUID(res.json()["user_id"]))[0]
    assert (float(stored["mpg_city"]), float(stored["mpg_hwy"])) == (car["mpg"]["city"], car["mpg"]["highway"])


def test_sign_up_without_a_car_still_works(client):
    res = client.post("/users", json={"nickname": "kai"})
    assert res.status_code == 201 and res.json()["vehicle"] is None


def test_sign_up_with_an_unknown_car_creates_no_user(client, vehicle_list):
    res = client.post("/users", json={"nickname": "kai", "vehicle": {**MAZDA5_2012, "year": 1999}})
    assert res.status_code == 422
    assert res.json()["error"]["code"] == "vehicle_not_found"
    assert query("SELECT count(*) FROM users")[0]["count"] == 0


def test_cost_model_receives_every_trip_and_event_field(client, model_inputs):
    _, headers = new_user(client)
    trip_id = upload(client, headers).json()["trip_id"]

    inputs = model_inputs[-1]
    # The car: the model's own Mazda5 profile, the only one it supports.
    assert inputs.vehicle == cost_model.SCORING_CONFIG["vehicle_profile"]
    assert inputs.vehicle["name"] == "2012 Mazda5 2.5L automatic (5-speed), FWD"
    # The trip.
    assert str(inputs.trip.trip_id) == trip_id
    assert inputs.trip.distance_mi == SAMPLE_TRIP["distance_mi"]
    assert inputs.trip.avg_speed_mph == SAMPLE_TRIP["avg_speed_mph"]
    assert inputs.trip.duration_s == 5 * 60
    assert (inputs.trip.events_complete, inputs.trip.detector_version, inputs.trip.is_demo) == (True, "ios-0.1.0", True)
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
    assert accel.speed_change_mph == 33.0
    assert accel.mean_accel_g > 0
    assert turn.avg_speed_mph == 21.0
    assert turn.heading_change_deg == 85.0
    # GPS speed readings: all of them for the trip, and 10 s before to 10 s after each event.
    assert len(inputs.trip.speed_samples) == len(SAMPLE_TRIP["speed_samples"])
    assert [s.sample_seq for s in brake.speed_samples] == list(range(20, 41))
    assert [s.speed_mps for s in brake.speed_samples] == [s["speed_mps"] for s in SAMPLE_TRIP["speed_samples"][20:41]]
    invalid = next(s for s in inputs.trip.speed_samples if s.sample_seq == 200)
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
        pytest.param(lambda t: t["events"][0].update(detector_version="ios-9.9.9"), id="event-detector-differs-from-trip"),
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
    trip = json.dumps(SAMPLE_TRIP).replace(f'"distance_mi": {SAMPLE_TRIP["distance_mi"]}', '"distance_mi": NaN')
    assert "NaN" in trip
    assert client.post("/trips", content=trip, headers=json_headers).status_code == 422
    car = '{"make": "HONDA", "equivalent_test_weight_lb": Infinity}'
    assert client.put("/users/me/vehicle", content=car, headers=json_headers).status_code == 422


def test_event_without_speeds_around_it_is_flagged_not_rejected(client, model_inputs):
    _, headers = new_user(client)
    trip = copy.deepcopy(SAMPLE_TRIP)
    trip["speed_samples"] = [s for s in trip["speed_samples"] if not 20 <= s["sample_seq"] < 30]  # nothing just before the brake
    res = upload(client, headers, trip)
    assert res.status_code == 201

    brake, accel, turn = model_inputs[-1].events
    assert brake.speed_window_complete is False
    assert accel.speed_window_complete and turn.speed_window_complete
    # The model needs readings at least every 3 s, so it keeps the trip unpriced.
    assert "gps_gap_over_three_seconds" in client.get(res.json()["receipt_url"], headers=headers).json()["error"]["message"]


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


def test_cost_model_input_without_optional_event_fields(client, model_inputs):
    _, headers = new_user(client)
    trip = copy.deepcopy(SAMPLE_TRIP)
    for event in trip["events"]:
        event.pop("duration_s", None)
        event.pop("heading_change_deg", None)
    assert upload(client, headers, trip).status_code == 201

    inputs = model_inputs[-1]
    assert all(e.duration_s is None and e.mean_accel_g is None and e.heading_change_deg is None for e in inputs.events)


MAZDA5_REFERENCE = "2012 Mazda5 2.5L automatic (5-speed), FWD"


def test_a_car_sent_as_free_form_data_is_priced_as_the_mazda5(client):
    _, headers = new_user(client)
    client.put("/users/me/vehicle", json={"make": "TOYOTA", "model": "PRIUS"}, headers=headers)
    trip_id = upload(client, headers).json()["trip_id"]

    assert client.get(f"/trips/{trip_id}/cost-input", headers=headers).json()["vehicle"] == cost_model.SCORING_CONFIG["vehicle_profile"]
    assert client.get(f"/trips/{trip_id}/receipt", headers=headers).json()["vehicle"] == MAZDA5_REFERENCE
    # The driver's own data stays on file as sent.
    assert client.get("/users/me/vehicle", headers=headers).json() == {"make": "TOYOTA", "model": "PRIUS"}


def sign_up(client, nickname, car):
    res = client.post("/users", json={"nickname": nickname, "vehicle": car})
    assert res.status_code == 201
    return res.json()["vehicle"], {"Authorization": f"Bearer {res.json()['token']}"}


CAMRY_2020 = {"make": "Toyota", "model": "CAMRY", "year": 2020}


def test_trips_are_priced_as_the_drivers_car(client, vehicle_list):
    _, mazda = new_user(client, "mazda")
    camry, toyota = sign_up(client, "camry", CAMRY_2020)
    mazda_trip, camry_trip = (upload(client, headers, fresh_trip()).json()["trip_id"] for headers in (mazda, toyota))  # the same drive

    receipt = client.get(f"/trips/{camry_trip}/receipt", headers=toyota).json()
    assert receipt["vehicle"] == "2020 Toyota CAMRY"
    shown = {a["key"]: a for a in receipt["assumptions"]}
    for parameter in camry["parameters"]:  # the car's own values, with the EPA list as their source
        assert shown[parameter["key"]]["value"] == parameter["value"]
        assert shown[parameter["key"]]["source_url"] == cost_model.EPA_TEST_CARS_URL
    model_input = client.get(f"/trips/{camry_trip}/cost-input", headers=toyota).json()["vehicle"]
    assert model_input["name"] == "2020 Toyota CAMRY" and model_input["parameters"]["idle_rate"] == shown["idle_rate"]["value"]

    # Same trip, different car: different amounts, and each car has its own configuration (and baseline).
    assert client.get(f"/trips/{mazda_trip}/receipt", headers=mazda).json()["vehicle"] == MAZDA5_REFERENCE
    assert trip_total(camry_trip) != pytest.approx(trip_total(mazda_trip), rel=1e-3)
    assert query("SELECT count(*) FROM scoring_configs")[0]["count"] == 2


def test_a_diesel_car_is_priced_at_the_diesel_price(client, vehicle_list):
    car, headers = sign_up(client, "ram", {"make": "Ram", "model": "1500 EcoDiesel29 4x2", "year": 2016})
    assert car["specs"]["fuel_type"] == "diesel"
    trip_id = upload(client, headers, fresh_trip()).json()["trip_id"]

    shown = {a["key"]: a for a in client.get(f"/trips/{trip_id}/receipt", headers=headers).json()["assumptions"]}
    assert "gas_price" not in shown
    diesel = cost_model.US_AVERAGE_DIESEL_PRICE
    assert (shown["diesel_price"]["value"], shown["diesel_price"]["source_url"]) == (diesel.value, diesel.source_url)
    assert client.get(f"/trips/{trip_id}/cost-input", headers=headers).json()["fuel_price"]["value"] == diesel.value


def test_a_car_the_model_cant_describe_is_priced_as_the_mazda5(client, vehicle_list):
    tesla = client.get("/vehicles/models", params={"make": "Tesla"}).json()["models"][0]
    year = client.get("/vehicles/years", params={"make": "Tesla", "model": tesla}).json()["years"][0]
    car, headers = sign_up(client, "tess", {"make": "Tesla", "model": tesla, "year": year})
    assert car["supported"] is False
    trip_id = upload(client, headers, fresh_trip()).json()["trip_id"]
    assert client.get(f"/trips/{trip_id}/receipt", headers=headers).json()["vehicle"] == MAZDA5_REFERENCE


def test_drivers_with_different_cars_rank_on_one_leaderboard(client, vehicle_list):
    _, mazda = new_user(client, "mazda")
    crew = client.post("/crews", json={"name": "Mixed"}, headers=mazda).json()
    _, camry = sign_up(client, "camry", CAMRY_2020)
    client.post(f"/crews/{crew['crew_id']}/join", json={"join_code": crew["join_code"]}, headers=camry)
    for headers in (mazda, camry):
        for _ in range(3):
            upload(client, headers, fresh_trip())
        upload(client, headers, fresh_trip(events=1))  # after the baseline, only the brake: both improve
    board = client.get("/leaderboard", headers=camry).json()
    assert {s["nickname"]: (s["state"], s["trips_counted"]) for s in board["standings"]} == {"mazda": ("ready", 1), "camry": ("ready", 1)}
    assert all(s["improvement_pct"] > 0 for s in board["standings"])


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
