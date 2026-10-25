"""Only run in the disposable cluster created by tests/run_sql_tests.py.

Exercises the production backend adapter and the analytics storage adapter using
the Swift-produced synthetic payload. No live service or real driver data.
"""
import argparse
import asyncio
from copy import deepcopy
from datetime import datetime
from decimal import Decimal
import json
from pathlib import Path
import sys
from uuid import UUID, uuid4

import asyncpg
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT), str(ROOT / "backend")]
import db
import repo
from errors import ApiError
from models.trips import TripCreate
from services.cost_model import SCORING_CONFIG
from drive_save_model.storage import score_stored_trip
from drive_save_model.validation import payload_from_trace


def unique(payload):
    payload = deepcopy(payload)
    payload["client_trip_id"] = str(uuid4())
    for e in payload["events"]:
        e["event_id"] = str(uuid4())
    return payload


async def store_for_analytics(conn, user, payload):
    trip = uuid4()
    await conn.execute(
        "INSERT INTO trips(id,user_id,client_trip_id,started_at,ended_at,distance_mi,source,is_demo,events_complete,detector_version) "
        "VALUES($1,$2,$1,$3,$4,$5,$6,true,$7,$8)", trip, user,
        datetime.fromisoformat(payload["started_at"]), datetime.fromisoformat(payload["ended_at"]),
        Decimal(str(payload["distance_mi"])), payload["source"], payload.get("events_complete", False), payload.get("detector_version"))
    await conn.executemany("INSERT INTO speed_samples(ts,trip_id,sample_seq,speed_mps,speed_accuracy_mps) VALUES($1,$2,$3,$4,$5)",
        [(datetime.fromisoformat(s["ts"]), trip, s["sample_seq"], s["speed_mps"], s["speed_accuracy_mps"]) for s in payload["speed_samples"]])
    await conn.executemany(
        "INSERT INTO trip_events(ts,event_id,trip_id,type,peak_g,speed_before_mph,speed_after_mph,detector_version,duration_s) "
        "VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)",
        [(datetime.fromisoformat(e["ts"]), uuid4(), trip, e["type"], e["peak_g"], e["speed_before_mph"],
          e["speed_after_mph"], e["detector_version"], e["duration_s"]) for e in payload["events"]])
    result = json.loads(await score_stored_trip(conn, user, trip, SCORING_CONFIG))
    return trip, result


async def run(socket, database):
    conn = await asyncpg.connect(host=socket, port=55439, database=database)
    try:
        await conn.execute((ROOT / "backend/db/002_event_details.sql").read_text())
        await conn.execute((ROOT / "backend/db/003_vehicle_catalog.sql").read_text())
        db._pool = await asyncpg.create_pool(host=socket, port=55439, database=database,
                                           min_size=1, max_size=2, init=db._init_connection)
        raw = json.loads((ROOT / "tests/fixtures/ios/swift-async-replay.json").read_text())
        complete = dict(raw, events_complete=True, detector_version="synthetic-ios-contract-v1")
        for adapter in ("analytics", "backend"):
            user_id = uuid4()
            await conn.execute("INSERT INTO users(id,nickname,token_hash) VALUES($1,$2,$3)", user_id, f"GPS {adapter}", str(user_id))
            user = repo.User(user_id, f"GPS {adapter}", None)
            baseline_ids = []
            for i, distance_factor in enumerate((1.05, .97, 1.02, .96)):
                payload = unique(complete)
                payload["distance_mi"] *= distance_factor
                if adapter == "analytics":
                    async with conn.transaction():
                        trip_id, receipt = await store_for_analytics(conn, user_id, payload)
                    details = receipt["model_result"]
                    assert receipt["status"] == "scored"
                    # Retry preserves the existing receipt and does not add metrics.
                    async with conn.transaction():
                        assert json.loads(await score_stored_trip(conn, user_id, trip_id, SCORING_CONFIG)) == receipt
                else:
                    validated = TripCreate.model_validate(payload)
                    trip_id, duplicate = await repo.accept_trip(user, validated)
                    assert not duplicate
                    assert await repo.accept_trip(user, validated) == (trip_id, True)
                    receipt = await repo.receipt(trip_id, user_id)
                    details = json.loads(await conn.fetchval("SELECT model_result FROM trips WHERE id=$1", trip_id))
                    assert receipt.scored_distance_mi == details["scored_distance_mi"]
                    assert receipt.scoring_duration_seconds == 300
                    assert receipt.scoring_started_at == datetime.fromisoformat(raw["speed_samples"][0]["ts"])
                    assert receipt.scoring_ended_at == datetime.fromisoformat(raw["speed_samples"][-1]["ts"])
                    assert receipt.monetary_scope == "observed_gps_window"
                    assert "gps_window_trimmed" in receipt.quality_flags
                    assert "GPS-covered portion only" in receipt.label
                    assert any("unpriced" in note for note in receipt.notes)
                row = await conn.fetchrow("SELECT started_at,ended_at,distance_mi,baseline_slot FROM trips WHERE id=$1", trip_id)
                assert row["started_at"] == datetime.fromisoformat(raw["started_at"])
                assert row["ended_at"] == datetime.fromisoformat(raw["ended_at"])
                assert row["baseline_slot"] == (i+1 if i < 3 else None)
                miles = await conn.fetchval("SELECT distance_mi FROM trip_metrics WHERE trip_id=$1", trip_id)
                assert miles == Decimal(str(details["scored_distance_mi"]))
                assert miles != row["distance_mi"]  # Raw upload is retained, never used as the scored denominator.
                if i < 3:
                    baseline_ids.append(trip_id)
                if i == 3 and adapter == "backend":
                    assert await conn.fetchval("SELECT amount_usd FROM savings_ledger WHERE trip_id=$1", trip_id) == 0
            baseline = await conn.fetchrow("SELECT * FROM drive_save_baseline($1,$2,true)", user_id, UUID(SCORING_CONFIG["id"]))
            totals = await conn.fetchrow("SELECT sum(avoidable_usd) AS usd,sum(distance_mi) AS miles FROM trip_metrics WHERE trip_id=ANY($1)", baseline_ids)
            # PostgreSQL and Python choose different decimal division scales.
            assert abs(baseline["baseline_usd_per_mile"] - totals["usd"] / totals["miles"]) < Decimal("1e-20")
            assert all(r["metrics_match"] for r in await conn.fetch("SELECT * FROM drive_save_quality($1,true)", user_id))

            # Current Swift upload remains insufficient: never silently assert completeness.
            payload = unique(raw)
            if adapter == "analytics":
                async with conn.transaction():
                    trip_id, failed = await store_for_analytics(conn, user_id, payload)
                assert failed["quality_flags"] == ["event_recording_incomplete"]
            else:
                trip_id, _ = await repo.accept_trip(user, TripCreate.model_validate(payload))
                try:
                    await repo.receipt(trip_id, user_id)
                    raise AssertionError("Incomplete detector produced a receipt")
                except ApiError as exc:
                    assert exc.code == "trip_not_scored" and "event_recording_incomplete" in exc.message
            assert not await conn.fetchval("SELECT EXISTS(SELECT 1 FROM trip_metrics WHERE trip_id=$1)", trip_id)

            # A reported mile cannot earn a baseline slot if only 59/60 mile was observed.
            boundary = payload_from_trace(np.arange(61.), np.full(61, 60 * .44704))
            short = {**boundary["trip_metadata"], "speed_samples": boundary["speed_samples"][:-1],
                     "events": [], "client_trip_id": str(uuid4()), "avg_speed_mph": 60}
            fresh_user = uuid4()
            await conn.execute("INSERT INTO users(id,nickname,token_hash) VALUES($1,'GPS short',$2)", fresh_user, str(fresh_user))
            if adapter == "analytics":
                async with conn.transaction():
                    trip_id, receipt = await store_for_analytics(conn, fresh_user, short)
                assert receipt["status"] == "scored"
            else:
                trip_id, _ = await repo.accept_trip(repo.User(fresh_user, "GPS short", None), TripCreate.model_validate(short))
                assert (await repo.receipt(trip_id, fresh_user)).scored_distance_mi == .983333
            assert await conn.fetchval("SELECT baseline_slot FROM trips WHERE id=$1", trip_id) is None
            assert await conn.fetchval("SELECT distance_mi FROM trip_metrics WHERE trip_id=$1", trip_id) == Decimal(".983333")
            print(f"PASS: {adapter}: Swift replay -> observed receipt; raw timestamps retained; retries; scored-mile baseline/metrics; incomplete detector; one-mile boundary")
    finally:
        await db.close()
        await conn.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--database", required=True, choices=("fresh", "upgrade"))
    args = parser.parse_args()
    asyncio.run(run(args.socket, args.database))
