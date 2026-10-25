"""Run only against the disposable database created by run_sql_tests.py."""

import argparse
import asyncio
from datetime import datetime, timedelta
import json
from pathlib import Path
import sys
from uuid import uuid4

import asyncpg

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from drive_save_model import scoring_config
from drive_save_model.storage import score_stored_trip
from drive_save_model.validation import example_payload, cruise_payload


async def run(socket, database):
    conn = await asyncpg.connect(host=socket, port=55439, database=database)
    try:
        config = scoring_config(3.5, price_as_of="2026-10-24")
        league = uuid4()
        await conn.execute("INSERT INTO public.leagues(id,name,join_code,is_demo) VALUES($1,'Model replay league',$2,true)", league, str(league))
        saved = []
        for player, mph in enumerate((65, 68, 71, 75)):
            user = uuid4()
            await conn.execute("INSERT INTO public.users(id,nickname,token_hash) VALUES($1,$2,$3)", user, f"Model Player {player}", str(user))
            await conn.execute("INSERT INTO public.league_members(user_id,league_id) VALUES($1,$2)", user, league)
            for trip_index in range(4):
                payload = cruise_payload(75 if trip_index < 3 else mph)
                trip = uuid4()
                start = datetime.fromisoformat(payload["trip_metadata"]["started_at"]) + timedelta(days=trip_index)
                end = start + timedelta(seconds=300)
                async with conn.transaction():
                    await conn.fetchrow("SELECT id FROM public.users WHERE id=$1 FOR UPDATE", user)
                    await conn.execute(
                        "INSERT INTO public.trips(id,user_id,client_trip_id,league_id,started_at,ended_at,distance_mi,source,is_demo,events_complete,detector_version) "
                        "VALUES($1,$2,$1,$3,$4,$5,$6,'synthetic',true,true,'synthetic-fixture-v1')",
                        trip, user, league, start, end, payload["trip_metadata"]["distance_mi"])
                    await conn.copy_records_to_table("speed_samples", schema_name="public",
                        columns=("ts", "trip_id", "sample_seq", "speed_mps", "speed_accuracy_mps"),
                        records=[(start + timedelta(seconds=i), trip, i, s["speed_mps"], 0.0)
                                 for i, s in enumerate(payload["speed_samples"])])
                    receipt = json.loads(await score_stored_trip(conn, user, trip, config))
                    assert receipt["status"] == "scored", receipt
                    assert receipt["model_result"]["validation_status"] == "laboratory_validation_pending"
                saved.append((user, trip))
        # This temporary database uses a live view, so historical replay dates appear immediately.
        rows = await conn.fetch("SELECT * FROM public.drive_save_leaderboard($1,'2026-10-22T12:00:00Z',true)", league)
        assert len(rows) == 4 and [r["rank"] for r in rows] == [1, 2, 3, 4]
        assert all(r["baseline_trip_count"] == 3 and r["trip_count"] == 1 for r in rows)
        assert not await conn.fetch("SELECT * FROM public.drive_save_leaderboard($1,now(),false)", league)
        user, trip = saved[0]
        counts = await conn.fetchrow("SELECT (SELECT count(*) FROM public.trips) AS trips,(SELECT count(*) FROM public.trip_metrics) AS metrics")
        async with conn.transaction():
            await score_stored_trip(conn, user, trip, config)
        assert counts == await conn.fetchrow("SELECT (SELECT count(*) FROM public.trips) AS trips,(SELECT count(*) FROM public.trip_metrics) AS metrics")
        assert await conn.fetchval("SELECT public.drive_save_receipt($1,$2)", trip, uuid4()) is None
        try:
            async with conn.transaction():
                await score_stored_trip(conn, uuid4(), trip, config)
        except ValueError as exc:
            assert str(exc) == "trip_not_found"
        else:
            raise AssertionError("Cross-user score allowed")
        try:
            await score_stored_trip(conn, user, trip, config)
        except ValueError as exc:
            assert "transaction" in str(exc)
        else:
            raise AssertionError("Non-atomic scoring allowed")
        try:
            async with conn.transaction():
                await score_stored_trip(conn, user, trip, scoring_config(4, price_as_of="2026-10-24"))
        except ValueError as exc:
            assert str(exc) == "already_scored_under_different_config"
        else:
            raise AssertionError("Scored trip was repriced")
        # A failure cannot consume a baseline slot or fabricate zero-dollar metrics.
        failed_trip = uuid4()
        async with conn.transaction():
            await conn.execute(
                "INSERT INTO public.trips(id,user_id,client_trip_id,started_at,ended_at,distance_mi,source,is_demo) "
                "VALUES($1,$2,$1,now()-interval '5 minutes',now(),1,'synthetic',true)", failed_trip,user)
            failed = json.loads(await score_stored_trip(conn,user,failed_trip,config))
            assert failed["status"] == "insufficient_data" and failed["fuel_gal"] is None
        assert not await conn.fetchval("SELECT EXISTS(SELECT 1 FROM public.trip_metrics WHERE trip_id=$1)", failed_trip)
        assert await conn.fetchval("SELECT baseline_slot FROM public.trips WHERE id=$1", failed_trip) is None
        # Prove caller rollback removes a scored trip and its projection together.
        rolled_back = uuid4()
        try:
            async with conn.transaction():
                await conn.execute(
                    "INSERT INTO public.trips(id,user_id,client_trip_id,started_at,ended_at,distance_mi,source,is_demo,events_complete,detector_version) "
                    "SELECT $1,user_id,$1,started_at,ended_at,distance_mi,source,is_demo,events_complete,detector_version FROM public.trips WHERE id=$2", rolled_back,trip)
                await conn.execute("INSERT INTO public.speed_samples SELECT ts,$1,sample_seq,speed_mps,speed_accuracy_mps FROM public.speed_samples WHERE trip_id=$2", rolled_back,trip)
                rolled_receipt = json.loads(await score_stored_trip(conn,user,rolled_back,config))
                assert rolled_receipt["status"] == "scored"
                raise RuntimeError("intentional rollback")
        except RuntimeError as exc:
            assert str(exc) == "intentional rollback"
        assert not await conn.fetchval("SELECT EXISTS(SELECT 1 FROM public.trips WHERE id=$1)", rolled_back)
        assert not await conn.fetchval("SELECT EXISTS(SELECT 1 FROM public.trip_metrics WHERE trip_id=$1)", rolled_back)
        # Three-event receipt is calculated from stored phone-format inputs, not client money.
        payload = example_payload()
        event_trip = uuid4()
        start = datetime.fromisoformat(payload["trip_metadata"]["started_at"])
        async with conn.transaction():
            await conn.execute("INSERT INTO public.trips(id,user_id,client_trip_id,started_at,ended_at,distance_mi,source,is_demo,events_complete,detector_version) VALUES($1,$2,$1,$3,$4,$5,'synthetic',true,true,'synthetic-fixture-v1')",
                event_trip,user,start,start+timedelta(seconds=300),payload["trip_metadata"]["distance_mi"])
            await conn.copy_records_to_table("speed_samples", schema_name="public",
                columns=("ts","trip_id","sample_seq","speed_mps","speed_accuracy_mps"),
                records=[(datetime.fromisoformat(s["ts"]),event_trip,s["sample_seq"],s["speed_mps"],0.) for s in payload["speed_samples"]])
            for e in payload["events"]:
                await conn.execute("INSERT INTO public.trip_events(ts,event_id,trip_id,type,peak_g,speed_before_mph,speed_after_mph,detector_version,duration_s,cost_usd) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,99)",
                    datetime.fromisoformat(e["ts"]),uuid4(),event_trip,e["type"],e["peak_g"],e["speed_before_mph"],e["speed_after_mph"],e["detector_version"],e["duration_s"])
            r = json.loads(await score_stored_trip(conn,user,event_trip,config))
            assert r["status"] == "scored", r
            assert len(r["events"]) == 3 and all(e["duration_s"] > 0 for e in r["events"])
            total = sum(e["cost_usd"] for e in r["events"]) + r["model_result"]["high_speed"]["cost_usd"]
            assert abs(total-r["avoidable_fuel_usd"]) < 0.000003
            assert all(e["cost_usd"] < 1 for e in r["events"])
        # Complete speed but incomplete event detector is never ranked as zero waste.
        incomplete = uuid4()
        async with conn.transaction():
            await conn.execute("INSERT INTO public.trips(id,user_id,client_trip_id,started_at,ended_at,distance_mi,source,is_demo) SELECT $1,user_id,$1,started_at,ended_at,distance_mi,source,is_demo FROM public.trips WHERE id=$2",incomplete,trip)
            await conn.execute("INSERT INTO public.speed_samples SELECT ts,$1,sample_seq,speed_mps,speed_accuracy_mps FROM public.speed_samples WHERE trip_id=$2",incomplete,trip)
            r = json.loads(await score_stored_trip(conn,user,incomplete,config))
            assert r["status"] == "insufficient_data" and r["avoidable_fuel_usd"] is None
            assert r["quality_flags"] == ["event_recording_incomplete"]
        assert not await conn.fetchval("SELECT EXISTS(SELECT 1 FROM public.trip_metrics WHERE trip_id=$1)",incomplete)
        print("PASS: Mazda5 math -> stored receipts -> 3-trip baselines -> 4 individual ranks; retry, ownership, rejection and rollback")
        print(json.dumps([{"rank":r["rank"], "name":r["nickname"], "improvement_pct":float(r["improvement_pct"])} for r in rows]))
    finally:
        await conn.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--database", required=True, choices=("fresh", "upgrade"))
    args = parser.parse_args()
    asyncio.run(run(args.socket, args.database))
