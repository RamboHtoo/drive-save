"""Optional asyncpg-compatible adapter. The caller owns authentication and ingestion.

Call inside the SAME transaction that inserts the trip/events/samples, after taking
the user row lock and checking client_trip_id retries. This module has no credentials
and makes no connections. CPU work is offloaded from the API's asyncio event loop.
"""

import asyncio
from decimal import Decimal
import json
from uuid import UUID

from .estimator import _valid_config, estimate_trip


def _numeric(value):
    """Send decimal text values to numeric columns; let PostgreSQL round to scale."""
    return None if value is None else Decimal(str(value))


async def score_stored_trip(conn, authenticated_user_id, trip_id, config):
    if not conn.is_in_transaction():
        raise ValueError("score_stored_trip requires the caller's ingestion transaction")
    user_id, trip_id = UUID(str(authenticated_user_id)), UUID(str(trip_id))
    profile = config.get("vehicle_profile") if isinstance(config, dict) else None
    _valid_config(profile, config)
    await conn.fetchrow("SELECT id FROM public.users WHERE id=$1 FOR UPDATE", user_id)
    trip = await conn.fetchrow(
        "SELECT * FROM public.trips WHERE id=$1 AND user_id=$2 FOR UPDATE", trip_id, user_id)
    if trip is None:
        raise ValueError("trip_not_found")
    if not trip["is_demo"]:
        raise ValueError("experimental_model_requires_demo_mode")
    if trip["status"] == "scored":
        if trip["scoring_config_id"] != UUID(config["id"]):
            raise ValueError("already_scored_under_different_config")
        return await conn.fetchval("SELECT public.drive_save_receipt($1,$2)", trip_id, user_id)
    samples = await conn.fetch(
        "SELECT ts,sample_seq,speed_mps,speed_accuracy_mps FROM public.speed_samples "
        "WHERE trip_id=$1 ORDER BY ts,sample_seq", trip_id)
    metadata = {key: trip[key] for key in ("started_at", "ended_at", "source", "is_demo", "events_complete", "detector_version")}
    metadata["distance_mi"] = float(trip["distance_mi"])
    events = await conn.fetch(
        "SELECT event_id,ts,type,duration_s,peak_g,speed_before_mph,speed_after_mph,detector_version "
        "FROM public.trip_events WHERE trip_id=$1 ORDER BY ts,event_id", trip_id)
    event_inputs = [{**dict(e), "event_id": str(e["event_id"])} for e in events]
    result = await asyncio.to_thread(estimate_trip, profile, [dict(s) for s in samples], metadata, config, event_inputs)
    await conn.execute("UPDATE public.trip_events SET cost_usd=NULL WHERE trip_id=$1", trip_id)
    for event in result["model_details"].get("events", []):
        await conn.execute("UPDATE public.trip_events SET cost_usd=$3 WHERE trip_id=$1 AND event_id=$2",
                           trip_id, UUID(event["event_id"]), _numeric(event["cost_usd"]))
    config_id, slot = None, None
    if result["status"] == "scored":
        config_id = UUID(config["id"])
        await conn.execute(
            "INSERT INTO public.scoring_configs(id,model_version,vehicle_profile,fuel_price_usd_per_gal,assumptions) "
            "VALUES($1,$2,$3::jsonb,$4,$5::jsonb) ON CONFLICT(id) DO NOTHING",
            config_id, config["model_version"], json.dumps(config["vehicle_profile"]),
            _numeric(config["fuel_price_usd_per_gal"]), json.dumps(config["assumptions"]))
        matches = await conn.fetchval(
            "SELECT model_version=$2 AND vehicle_profile=$3::jsonb AND fuel_price_usd_per_gal=$4 "
            "AND assumptions=$5::jsonb FROM public.scoring_configs WHERE id=$1",
            config_id, config["model_version"], json.dumps(config["vehicle_profile"]),
            _numeric(config["fuel_price_usd_per_gal"]), json.dumps(config["assumptions"]))
        if not matches:
            raise ValueError("stored_scoring_config_conflict")
        scored_distance = result["model_details"]["scored_distance_mi"]
        if min(metadata["distance_mi"], scored_distance) >= 1:
            count = await conn.fetchval(
                "SELECT count(*) FROM public.trips WHERE user_id=$1 AND scoring_config_id=$2 "
                "AND is_demo AND baseline_slot IS NOT NULL", user_id, config_id)
            slot = count + 1 if count < 3 else None
    await conn.execute(
        "UPDATE public.trips SET status=$3,scoring_config_id=$4,fuel_gal=$5,avoidable_usd=$6,"
        "baseline_slot=$7,quality_flags=$8::jsonb,model_result=$9::jsonb WHERE id=$1 AND user_id=$2",
        trip_id, user_id, result["status"], config_id, _numeric(result["fuel_gal"]), _numeric(result["avoidable_usd"]),
        slot, json.dumps(result["quality_flags"]), json.dumps(result["model_details"], allow_nan=False))
    if result["status"] == "scored":
        await conn.execute(
            "INSERT INTO public.trip_metrics(ts,trip_id,user_id,league_id,scoring_config_id,distance_mi,"
            "fuel_gal,avoidable_usd,is_baseline,is_demo) SELECT started_at,id,user_id,league_id,"
            "scoring_config_id,$2,fuel_gal,avoidable_usd,baseline_slot IS NOT NULL,is_demo "
            "FROM public.trips WHERE id=$1", trip_id, _numeric(scored_distance))
    return await conn.fetchval("SELECT public.drive_save_receipt($1,$2)", trip_id, user_id)
