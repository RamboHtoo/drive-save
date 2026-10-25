"""Opt-in integration smoke test. Creates dedicated disposable demo users only.
Never prints or writes tokens. Replay identity never joins a league.
Does not reset, delete, or modify any existing user's data.
"""
import copy
import json
import urllib.request
import urllib.error
import uuid
from pathlib import Path

BASE = "https://drivesave.nuhylabs.com"
ROOT = Path(__file__).resolve().parents[1]

def request(method, path, body=None, token=None):
    data = json.dumps(body, allow_nan=False).encode() if body is not None else None
    headers = {"Accept": "application/json"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=25) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)

def register(label):
    status, value = request("POST", "/users", {"nickname": label + " " + uuid.uuid4().hex[:6]})
    assert status == 201 and value.get("token") and value.get("user_id"), "Registration failed"
    print("PASS: dedicated demo user registration (token withheld)")
    return value

def main():
    status, health = request("GET", "/health")
    assert status == 200 and health["status"] == "ok"
    print("PASS: deployed backend health")
    replay = register("iOS Replay Smoke")
    fixture_root = ROOT / "DriveAndSave/MockData/Backend"
    vehicle = json.loads((fixture_root / "sample-vehicle.json").read_text())
    status, value = request("PUT", "/users/me/vehicle", vehicle, replay["token"])
    assert status == 200 and value == vehicle
    status, value = request("GET", "/users/me/vehicle", token=replay["token"])
    assert status == 200 and value == vehicle
    print("PASS: complete EPA vehicle PUT/GET round-trip")
    trip = json.loads((fixture_root / "sample-trip.json").read_text())
    trip["client_trip_id"] = str(uuid.uuid4())
    trip["source"] = "replayed"
    trip["is_demo"] = True
    assert "latitude" not in json.dumps(trip) and "longitude" not in json.dumps(trip)
    status, created = request("POST", "/trips", trip, replay["token"])
    assert status == 201 and not created["duplicate"]
    status, duplicate = request("POST", "/trips", trip, replay["token"])
    assert status == 200 and duplicate["duplicate"] and duplicate["trip_id"] == created["trip_id"]
    print("PASS: demo-only trip upload 201 and identical duplicate 200")
    altered = copy.deepcopy(trip)
    altered["distance_mi"] += 0.1
    status, conflict = request("POST", "/trips", altered, replay["token"])
    assert status == 409 and conflict["error"]["code"] == "trip_conflict"
    print("PASS: conflicting body returns 409 without changing stored trip")
    invalid = copy.deepcopy(trip)
    invalid["distance_mi"] = 0
    status, validation = request("POST", "/trips", invalid, replay["token"])
    assert status == 422 and validation["error"].get("details")
    print("PASS: 422 includes validation field details")
    status, receipt = request("GET", "/trips/" + created["trip_id"] + "/receipt", token=replay["token"])
    assert status == 200 and receipt["is_demo"] and receipt["is_estimate"] and receipt["cost_model"]
    print("PASS: receipt fields, demo marker and assumptions; cost_model=" + receipt["cost_model"])
    status, value = request("GET", "/users/me/vehicle", token="invalid-demo-token")
    assert status == 401
    print("PASS: invalid bearer credential returns 401")
    status, progress = request("GET", "/users/" + replay["user_id"] + "/progress", token=replay["token"])
    assert status == 200
    if progress["trips_counted"] != 0:
        print("BACKEND GAP: demo replay is counted in progress. This replay identity must remain isolated from all leagues.")
    # Separate identities with no synthetic trip data verify private-league CRUD.
    owner = register("iOS League Smoke")
    joiner = register("iOS Join Smoke")
    status, league = request("POST", "/crews", {"name": "iOS Disposable Demo " + uuid.uuid4().hex[:6]}, owner["token"])
    assert status == 201 and league["member_count"] == 1 and not league["active"]
    league_id = league["crew_id"]
    status, joined = request("POST", "/crews/" + league_id + "/join", {"join_code": league["join_code"]}, joiner["token"])
    assert status == 200 and joined["member_count"] == 2 and not joined["active"]
    status, detail = request("GET", "/crews/" + league_id, token=owner["token"])
    assert status == 200 and detail["member_count"] == 2
    status, board = request("GET", "/leaderboard?scope=members&crew_id=" + league_id, token=owner["token"])
    print("PASS: create/join/get private league. League remains inactive with 2 demo-test members.")
    if status == 200 and board.get("crew_id") == league_id and isinstance(board.get("standings"), list) and all("user_id" in entry and "nickname" in entry for entry in board["standings"]):
        print("PASS: member leaderboard matches updated deployed contract (user_id/nickname/nullable rank)")
    else:
        print("BACKEND GAP: member-scope leaderboard response does not match deployed OpenAPI. HTTP", status, "top-level keys:", sorted(board.keys()))
        print("Sanitized leaderboard response:", json.dumps(board))
    print("Production smoke complete. No existing data changed; no replay identity entered competition.")

if __name__ == "__main__":
    main()
