"""Creates the four-player demo league through the API: three rival drivers with their
baselines and this week's trips already ranked, and a join code for the presenter's iPhone.

    python backend/scripts/seed_demo_league.py
    python backend/scripts/seed_demo_league.py --base-url http://localhost:8000

Only the standard library is needed. Every trip is a variant of fixtures/sample-trip.json
with every speed scaled, so the fuel model still accepts it: three baseline trips near 1.0x,
then one trip this week. The weekly factors were searched against each car's EPA parameters
and the fuel prices of 2026-10-19 to rank the rivals at about +20%, +5% and -10%; another
price or model version moves those numbers a little.

Each run creates a new league and new accounts; nothing is reused or deleted. The week
starts Monday 00:00 UTC, so run it again in a new week. The join code, ids and tokens go
to backend/demo-league-credentials.txt (git-ignored); keep the tokens out of Git and chat.
"""

import argparse
import copy
import json
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
SAMPLE_TRIP = BACKEND.parent / "fixtures" / "sample-trip.json"
DEFAULT_OUT = BACKEND / "demo-league-credentials.txt"
DEFAULT_BASE_URL = "https://drivesave.nuhylabs.com"
LEAGUE_NAME = "Drive Save Demo League"

# Nickname, car from the vehicle list, and the speed factor of this week's trip.
RIVALS = [
    ("Alex", {"make": "Toyota", "model": "CAMRY", "year": 2020}, 0.9715),
    ("Blair", {"make": "Honda", "model": "CIVIC", "year": 2015}, 0.9933),
    ("Casey", {"make": "Ford", "model": "F150 PICKUP 2WD", "year": 2024}, 1.0134),
]
BASELINE_FACTORS = (0.99, 1.0, 1.01)


def _parse(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def _iso(moment: datetime) -> str:
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def trip_variant(sample: dict, factor: float, start: datetime) -> dict:
    """The sample trip moved to start at `start`, with every speed and the distance scaled by `factor`."""
    shift = start - _parse(sample["started_at"])
    trip = copy.deepcopy(sample)
    trip.update(
        client_trip_id=str(uuid.uuid4()),
        started_at=_iso(start),
        ended_at=_iso(_parse(trip["ended_at"]) + shift),
        distance_mi=round(trip["distance_mi"] * factor, 4),
        avg_speed_mph=round(trip["avg_speed_mph"] * factor, 2),
        source="synthetic",
        is_demo=True,
    )
    for event in trip["events"]:
        event["event_id"] = str(uuid.uuid4())
        event["ts"] = _iso(_parse(event["ts"]) + shift)
        event["speed_before_mph"] = round(event["speed_before_mph"] * factor, 2)
        event["speed_after_mph"] = round(event["speed_after_mph"] * factor, 2)
    for reading in trip["speed_samples"]:
        reading["ts"] = _iso(_parse(reading["ts"]) + shift)
        if reading["speed_mps"] is not None and reading["speed_mps"] >= 0:  # negative means invalid; keep it so
            reading["speed_mps"] = round(reading["speed_mps"] * factor, 4)
    return trip


class Api:
    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")

    def call(self, method: str, path: str, body: dict | None = None, token: str | None = None) -> dict:
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.base_url + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            sys.exit(f"{method} {path} failed with {error.code}: {error.read().decode()}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()

    api = Api(args.base_url)
    sample = json.loads(SAMPLE_TRIP.read_text())
    now = datetime.now(timezone.utc).replace(microsecond=0)
    week_start = datetime.combine((now - timedelta(days=now.weekday())).date(), datetime.min.time(), timezone.utc)
    if now - week_start < timedelta(hours=4):
        sys.exit("This week started less than 4 hours ago; wait so this week's trips fit before now.")

    drivers = []
    for nickname, car, _ in RIVALS:
        user = api.call("POST", "/users", {"nickname": nickname, "vehicle": car})
        drivers.append({"nickname": nickname, "user_id": user["user_id"], "token": user["token"]})
        print(f"Signed up {nickname} ({car['year']} {car['make']} {car['model']})")

    league = api.call("POST", "/crews", {"name": LEAGUE_NAME}, drivers[0]["token"])
    for driver in drivers[1:]:
        api.call("POST", f"/crews/{league['crew_id']}/join", {"join_code": league["join_code"]}, driver["token"])
    print(f"Created {LEAGUE_NAME!r} with join code {league['join_code']}")

    for i, (driver, (_, _, weekly_factor)) in enumerate(zip(drivers, RIVALS)):
        # Baselines over the three days before now; this week's trip a few hours ago.
        starts = [now - timedelta(days=3 - k, hours=6 + i) for k in range(3)]
        trips = [*zip(BASELINE_FACTORS, starts), (weekly_factor, now - timedelta(hours=2, minutes=30 * i))]
        for factor, start in trips:
            created = api.call("POST", "/trips", trip_variant(sample, factor, start), driver["token"])
            receipt = api.call("GET", created["receipt_url"], token=driver["token"])
            print(f"  {driver['nickname']}: trip at {_iso(start)} x{factor}, ${receipt['avoidable_cost_usd']}")

    print("Waiting for this week's trips to reach the leaderboard (the aggregate refreshes every minute)...")
    for _ in range(18):
        board = api.call("GET", "/leaderboard?period=week", token=drivers[0]["token"])
        if sum(s["state"] == "ready" for s in board["standings"]) == len(drivers):
            break
        time.sleep(10)
    for s in board["standings"]:
        print(f"  #{s['rank']} {s['nickname']}: {s['improvement_pct']}% (${s['est_savings_usd']}), {s['state']}")

    lines = [
        f"# Demo league seeded {_iso(now)} on {args.base_url}. Tokens are test credentials; keep them out of Git and chat.",
        f"league_name={LEAGUE_NAME}",
        f"league_id={league['crew_id']}",
        f"join_code={league['join_code']}",
        *(f"{d['nickname'].lower()}_user_id={d['user_id']}\n{d['nickname'].lower()}_token={d['token']}" for d in drivers),
    ]
    args.out.write_text("\n".join(lines) + "\n")
    print(f"Join code {league['join_code']}; ids and tokens written to {args.out}")


if __name__ == "__main__":
    main()
