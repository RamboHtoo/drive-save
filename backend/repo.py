"""Database access for the API (Tiger Data: Postgres + TimescaleDB).

Tables and analytics functions come from analytics/schema.sql and
analytics/queries.sql (schema v4, owned by the data teammate), plus
backend/db/002_event_details.sql and 003_vehicle_catalog.sql. The rules for uploads, baselines and metrics
follow docs/database-setup.md. The API's crews are the schema's leagues: tables
leagues and league_members, column league_id.
"""

import asyncio
from collections.abc import Callable
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal
from uuid import UUID

import asyncpg
from pydantic import JsonValue

import db
from errors import ApiError
from models.cost_model import CostModelInput, CostModelOutput
from models.crews import MIN_ACTIVE_MEMBERS
from models.leaderboard import Leaderboard, Period, Standing
from models.trips import Assumption, Receipt, ReceiptEvent, SpeedSample, TripCreate, TripEventIn
from models.users import Progress, WeeklyPoint
from models.vehicles import MpgEstimate, Vehicle, VehicleSource, VehicleSpecs
from services import cost_model
from services.epa_dataset import model_key

BASELINE_TRIPS = 3
MIN_BASELINE_MILES = 1
PROGRESS_WEEKS = 8


def _dec(value: float) -> Decimal:
    return Decimal(str(value))


def _float(value: Decimal | float | None, digits: int) -> float | None:
    return None if value is None else round(float(value), digits)


def _week_start(moment: datetime) -> datetime:
    """Monday 00:00 UTC of the week containing moment."""
    day = moment.astimezone(timezone.utc).date()
    return datetime.combine(day - timedelta(days=day.weekday()), time(), timezone.utc)


# ---- Users ----------------------------------------------------------------------------------


@dataclass
class User:
    user_id: UUID
    nickname: str
    vehicle: dict[str, JsonValue] | None


async def create_user(nickname: str, token_hash: str, vehicle: Vehicle | None = None) -> UUID:
    mpg = vehicle.mpg if vehicle else None
    return await db.pool().fetchval(
        "INSERT INTO users (nickname, token_hash, vehicle, mpg_city, mpg_hwy) VALUES ($1, $2, $3, $4, $5) RETURNING id",
        nickname,
        token_hash,
        vehicle.model_dump(mode="json") if vehicle else None,
        _dec(mpg.city) if mpg and mpg.city else None,
        _dec(mpg.highway) if mpg and mpg.highway else None,
    )


async def user_by_token_hash(token_hash: str) -> User | None:
    row = await db.pool().fetchrow("SELECT id, nickname, vehicle FROM users WHERE token_hash = $1", token_hash)
    return User(row["id"], row["nickname"], row["vehicle"]) if row else None


async def set_vehicle(user_id: UUID, vehicle: dict[str, JsonValue]) -> None:
    await db.pool().execute("UPDATE users SET vehicle = $2 WHERE id = $1", user_id, vehicle)


# ---- Vehicle list ---------------------------------------------------------------------------
# vehicle_models (backend/db/003_vehicle_catalog.sql), loaded from the EPA Test Car List by
# scripts/load_vehicles.py. Lookups go through the same upper-case keys the loader stored.


async def vehicle_makes() -> list[str]:
    rows = await db.pool().fetch("SELECT DISTINCT make_key, make FROM vehicle_models ORDER BY make_key")
    return [r["make"] for r in rows]


async def vehicle_models(make: str) -> tuple[str, list[str]] | None:
    """(the brand as listed, its models), or None for a brand that isn't in the list."""
    rows = await db.pool().fetch("SELECT DISTINCT model_key, make, model FROM vehicle_models WHERE make_key = $1 ORDER BY model_key", model_key(make))
    return (rows[0]["make"], [r["model"] for r in rows]) if rows else None


async def vehicle_years(make: str, model: str) -> tuple[str, str, list[int]] | None:
    rows = await db.pool().fetch(
        "SELECT make, model, model_year FROM vehicle_models WHERE make_key = $1 AND model_key = $2 ORDER BY model_year DESC",
        model_key(make),
        model_key(model),
    )
    return (rows[0]["make"], rows[0]["model"], [r["model_year"] for r in rows]) if rows else None


async def vehicle(make: str, model: str, year: int) -> Vehicle | None:
    row = await db.pool().fetchrow(
        "SELECT * FROM vehicle_models WHERE make_key = $1 AND model_key = $2 AND model_year = $3", model_key(make), model_key(model), year
    )
    if row is None:
        return None
    return Vehicle(
        vehicle_id=row["id"],
        make=row["make"],
        model=row["model"],
        year=row["model_year"],
        supported=row["supported"],
        specs=VehicleSpecs(
            fuel_type=row["fuel_type"],
            vehicle_type=row["vehicle_type"],
            engine_displacement_l=row["displacement_l"],
            cylinders=row["cylinders"],
            rated_horsepower=row["rated_hp"],
            transmission=row["transmission"],
            gears=row["gears"],
            drive=row["drive"],
            test_weight_lb=row["etw_lb"],
        ),
        mpg=MpgEstimate(city=_float(row["label_city_mpg"], 1), highway=_float(row["label_highway_mpg"], 1), combined=_float(row["label_combined_mpg"], 1)),
        parameters=row["parameters"],
        flags=row["flags"],
        source=VehicleSource(test_vehicle_id=row["test_vehicle_id"], test_configuration=row["test_configuration"], configurations_tested=row["variant_count"]),
    )


# ---- Crews ----------------------------------------------------------------------------------


@dataclass
class CrewMember:
    user_id: UUID
    nickname: str
    joined_at: datetime


@dataclass
class Crew:
    crew_id: UUID
    name: str
    join_code: str
    is_demo: bool
    members: list[CrewMember]


async def _join(conn: asyncpg.Connection, crew_id: UUID, user_id: UUID) -> None:
    # One crew per driver: joining another crew moves them; rejoining the same crew keeps joined_at.
    await conn.execute(
        """
        INSERT INTO league_members (user_id, league_id) VALUES ($1, $2)
        ON CONFLICT (user_id) DO UPDATE SET league_id = EXCLUDED.league_id, joined_at = now()
        WHERE league_members.league_id IS DISTINCT FROM EXCLUDED.league_id
        """,
        user_id,
        crew_id,
    )


async def create_crew(name: str, creator_id: UUID, new_join_code: Callable[[], str]) -> UUID:
    for _ in range(5):  # retry on the rare join-code collision
        try:
            async with db.pool().acquire() as conn, conn.transaction():
                crew_id = await conn.fetchval(
                    "INSERT INTO leagues (name, join_code, is_demo) VALUES ($1, $2, $3) RETURNING id", name, new_join_code(), cost_model.DEMO_ONLY
                )
                await _join(conn, crew_id, creator_id)
                return crew_id
        except asyncpg.UniqueViolationError:
            continue
    raise ApiError(500, "join_code_unavailable", "Couldn't create a unique join code; try again")


async def join_crew(crew_id: UUID, user_id: UUID) -> None:
    async with db.pool().acquire() as conn:
        await _join(conn, crew_id, user_id)


async def get_crew(crew_id: UUID) -> Crew | None:
    row = await db.pool().fetchrow("SELECT id, name, join_code, is_demo FROM leagues WHERE id = $1", crew_id)
    if row is None:
        return None
    members = await db.pool().fetch(
        """
        SELECT u.id, u.nickname, cm.joined_at FROM league_members cm JOIN users u ON u.id = cm.user_id
        WHERE cm.league_id = $1 ORDER BY cm.joined_at, u.nickname
        """,
        crew_id,
    )
    return Crew(row["id"], row["name"], row["join_code"], row["is_demo"], [CrewMember(*m) for m in members])


# ---- Trips ----------------------------------------------------------------------------------


async def accept_trip(user: User, trip: TripCreate) -> tuple[UUID, bool]:
    """Stores and prices a trip atomically. Returns (trip_id, duplicate)."""
    if cost_model.DEMO_ONLY:  # override what the app sent, before comparing retries
        trip = trip.model_copy(update={"is_demo": True})
    async with db.pool().acquire() as conn, conn.transaction():
        # Serialize this driver's uploads so duplicate checks and baseline slots stay consistent.
        await conn.execute("SELECT 1 FROM users WHERE id = $1 FOR UPDATE", user.user_id)
        existing = await conn.fetchval("SELECT id FROM trips WHERE user_id = $1 AND client_trip_id = $2", user.user_id, trip.client_trip_id)
        if existing:
            if await _load_trip(conn, existing) != trip:
                raise ApiError(409, "trip_conflict", "A different trip was already uploaded with this client_trip_id")
            return existing, True

        trip_id = await conn.fetchval(
            """
            INSERT INTO trips (user_id, client_trip_id, league_id, started_at, ended_at, distance_mi, avg_speed_mph, source, is_demo,
                               events_complete, detector_version)
            VALUES ($1, $2, (SELECT league_id FROM league_members WHERE user_id = $1), $3, $4, $5, $6, $7, $8, $9, $10)
            RETURNING id
            """,
            user.user_id,
            trip.client_trip_id,
            trip.started_at,
            trip.ended_at,
            _dec(trip.distance_mi),
            trip.avg_speed_mph,
            trip.source,
            trip.is_demo,
            trip.events_complete,
            trip.detector_version,
        )

        vehicle = await _pricing_vehicle(conn, user.vehicle)
        inputs = cost_model.build_input(cost_model.PricingRequest(trip_id, trip, vehicle))
        result = await asyncio.to_thread(cost_model.estimate, inputs)  # CPU work, kept off the event loop
        if len(result.event_costs_usd) != len(trip.events):
            raise ApiError(500, "cost_model_error", "The cost model must return one cost per event")

        await conn.executemany(
            """
            INSERT INTO trip_events (ts, event_id, trip_id, type, peak_g, speed_before_mph, speed_after_mph,
                                     detector_version, cost_usd, duration_s, heading_change_deg)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
            """,
            [
                (e.ts, e.event_id, trip_id, e.type.value, e.peak_g, e.speed_before_mph, e.speed_after_mph,
                 e.detector_version, None if cost is None else _dec(cost), e.duration_s, e.heading_change_deg)
                for e, cost in zip(trip.events, result.event_costs_usd)
            ],
        )
        await conn.executemany(
            "INSERT INTO speed_samples (ts, trip_id, sample_seq, speed_mps, speed_accuracy_mps) VALUES ($1, $2, $3, $4, $5)",
            [(s.ts, trip_id, s.sample_seq, s.speed_mps, s.speed_accuracy_mps) for s in trip.speed_samples],
        )

        if result.status == "scored":
            await _record_score(conn, user, trip, trip_id, result, cost_model.scoring_config_for(vehicle))
        else:
            await conn.execute(
                "UPDATE trips SET status = 'insufficient_data', quality_flags = $2, model_result = $3 WHERE id = $1",
                trip_id,
                result.quality_flags,
                result.details,
            )
    return trip_id, False


async def _pricing_vehicle(conn: asyncpg.Connection, driver_vehicle: dict[str, JsonValue] | None) -> dict[str, JsonValue]:
    """The vehicle the model prices a driver's trips as: their car from the vehicle list with its own
    parameters, or the model's 2012 Mazda5 when they have no car there that it supports."""
    try:
        vehicle_id = UUID(str((driver_vehicle or {})["vehicle_id"]))
    except (KeyError, ValueError):  # no car, or one sent as free-form data with PUT /users/me/vehicle
        return cost_model.SCORING_CONFIG["vehicle_profile"]
    row = await conn.fetchrow("SELECT vehicle_profile, parameters, fuel_type FROM vehicle_models WHERE id = $1 AND supported", vehicle_id)
    if row is None:  # an electric car, say, or a car no longer in the list
        return cost_model.SCORING_CONFIG["vehicle_profile"]
    return cost_model.car_profile(row["vehicle_profile"], row["parameters"], row["fuel_type"])


async def _scoring_config(conn: asyncpg.Connection, config: dict) -> UUID:
    """A configuration is immutable and its id comes from its content, so storing it is idempotent."""
    config_id = UUID(config["id"])
    await conn.execute(
        """
        INSERT INTO scoring_configs (id, model_version, vehicle_profile, fuel_price_usd_per_gal, assumptions)
        VALUES ($1, $2, $3, $4, $5) ON CONFLICT (id) DO NOTHING
        """,
        config_id,
        config["model_version"],
        config["vehicle_profile"],
        _dec(config["fuel_price_usd_per_gal"]),
        config["assumptions"],
    )
    return config_id


async def _record_score(conn: asyncpg.Connection, user: User, trip: TripCreate, trip_id: UUID, result: CostModelOutput, config: dict) -> None:
    config_id = await _scoring_config(conn, config)
    avoidable = result.avoidable_usd

    # Baseline: the first 3 scored trips of at least a mile, per driver, configuration and demo flag.
    slot = None
    if trip.distance_mi >= MIN_BASELINE_MILES:
        used = await conn.fetchval(
            "SELECT count(*) FROM trips WHERE user_id = $1 AND scoring_config_id = $2 AND is_demo = $3 AND baseline_slot IS NOT NULL",
            user.user_id,
            config_id,
            trip.is_demo,
        )
        if used < BASELINE_TRIPS:
            slot = used + 1

    await conn.execute(
        """
        UPDATE trips SET status = 'scored', scoring_config_id = $2, fuel_gal = $3, avoidable_usd = $4, baseline_slot = $5,
                         quality_flags = $6, model_result = $7
        WHERE id = $1
        """,
        trip_id,
        config_id,
        _dec(result.fuel_gal),
        _dec(avoidable),
        slot,
        result.quality_flags,
        result.details,
    )
    await conn.execute(
        """
        INSERT INTO trip_metrics (ts, trip_id, user_id, league_id, scoring_config_id, distance_mi, fuel_gal, avoidable_usd, is_baseline, is_demo)
        SELECT started_at, id, user_id, league_id, scoring_config_id, distance_mi, fuel_gal, avoidable_usd, baseline_slot IS NOT NULL, is_demo
        FROM trips WHERE id = $1
        """,
        trip_id,
    )

    if slot is None:  # a later trip: record the signed estimated improvement against the frozen baseline
        baseline = await conn.fetchrow("SELECT * FROM drive_save_baseline($1, $2, $3)", user.user_id, config_id, trip.is_demo)
        if baseline["state"] == "ready":
            amount = baseline["baseline_usd_per_mile"] * _dec(trip.distance_mi) - _dec(avoidable)
            await conn.execute("INSERT INTO savings_ledger (trip_id, user_id, amount_usd) VALUES ($1, $2, $3)", trip_id, user.user_id, amount)


async def _load_trip(conn: asyncpg.Connection, trip_id: UUID) -> TripCreate:
    """Rebuilds the upload exactly as validated, to compare retries and to show the model input."""
    t = await conn.fetchrow(
        """
        SELECT client_trip_id, started_at, ended_at, distance_mi, avg_speed_mph, source, is_demo, events_complete, detector_version
        FROM trips WHERE id = $1
        """,
        trip_id,
    )
    events = await conn.fetch(
        """
        SELECT event_id, type, ts, detector_version, peak_g, speed_before_mph, speed_after_mph, duration_s, heading_change_deg
        FROM trip_events WHERE trip_id = $1 ORDER BY ts, event_id
        """,
        trip_id,
    )
    samples = await conn.fetch(
        "SELECT ts, sample_seq, speed_mps, speed_accuracy_mps FROM speed_samples WHERE trip_id = $1 ORDER BY ts, sample_seq",
        trip_id,
    )
    return TripCreate(
        client_trip_id=t["client_trip_id"],
        started_at=t["started_at"],
        ended_at=t["ended_at"],
        distance_mi=float(t["distance_mi"]),
        avg_speed_mph=t["avg_speed_mph"],
        source=t["source"],
        is_demo=t["is_demo"],
        events_complete=t["events_complete"],
        detector_version=t["detector_version"],
        events=[TripEventIn(**dict(e)) for e in events],
        speed_samples=[SpeedSample(**dict(s)) for s in samples],
    )


async def _owned_trip(conn: asyncpg.Connection, trip_id: UUID, user_id: UUID) -> asyncpg.Record:
    row = await conn.fetchrow(
        """
        SELECT t.user_id, t.status, t.distance_mi, t.avoidable_usd, t.is_demo, t.quality_flags, t.model_result,
               sc.model_version, sc.assumptions, sc.vehicle_profile
        FROM trips t LEFT JOIN scoring_configs sc ON sc.id = t.scoring_config_id
        WHERE t.id = $1
        """,
        trip_id,
    )
    if row is None:
        raise ApiError(404, "trip_not_found", "No trip with that id")
    if row["user_id"] != user_id:
        raise ApiError(403, "forbidden", "You can only view your own trips")
    return row


async def receipt(trip_id: UUID, user_id: UUID) -> Receipt:
    async with db.pool().acquire() as conn:
        t = await _owned_trip(conn, trip_id, user_id)
        if t["status"] != "scored":
            reasons = ", ".join(t["quality_flags"]) or "it hasn't been priced"
            raise ApiError(409, "trip_not_scored", f"The fuel model couldn't price this trip: {reasons}")
        events = await conn.fetch(
            "SELECT type, ts, speed_before_mph, speed_after_mph, cost_usd FROM trip_events WHERE trip_id = $1 ORDER BY ts, event_id",
            trip_id,
        )
    details = t["model_result"] or {}  # empty for trips priced before the Mazda5 model
    numeric = [a for a in t["assumptions"] if _is_number(a["value"]) and a["unit"]]
    return Receipt(
        trip_id=trip_id,
        distance_mi=float(t["distance_mi"]),
        events=[
            ReceiptEvent(
                type=e["type"],
                ts=e["ts"],
                speed_before_mph=e["speed_before_mph"],
                speed_after_mph=e["speed_after_mph"],
                cost_usd=_float(e["cost_usd"], 4),
            )
            for e in events
        ],
        avoidable_cost_usd=_float(t["avoidable_usd"], 4),
        high_speed_cost_usd=_float(details.get("cost_breakdown_usd", {}).get("high_speed"), 4),
        cost_model=t["model_version"],
        vehicle=(t["vehicle_profile"] or {}).get("name"),
        label=details.get("receipt_label"),
        assumptions=[Assumption(**a) for a in numeric],
        notes=[f"{a['key']}: {a['value']}" for a in t["assumptions"] if a not in numeric],
        is_demo=t["is_demo"],
    )


def _is_number(value: JsonValue) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


async def cost_input(trip_id: UUID, user_id: UUID) -> CostModelInput:
    async with db.pool().acquire() as conn:
        t = await _owned_trip(conn, trip_id, user_id)
        trip = await _load_trip(conn, trip_id)
        # A priced trip keeps the vehicle it was priced as. An unpriced one has no stored configuration:
        # show the driver's car as it is now, which is what the model got unless they changed cars since.
        vehicle = t["vehicle_profile"] or await _pricing_vehicle(conn, await conn.fetchval("SELECT vehicle FROM users WHERE id = $1", user_id))
    return cost_model.build_input(cost_model.PricingRequest(trip_id, trip, vehicle))


# ---- Progress and leaderboard -----------------------------------------------------------------


async def progress(user_id: UUID) -> Progress:
    week = _week_start(datetime.now(timezone.utc))
    demo = cost_model.DEMO_ONLY
    async with db.pool().acquire() as conn:
        trips_counted = await conn.fetchval("SELECT count(*) FROM trips WHERE user_id = $1 AND is_demo = $2", user_id, demo)
        config_id = await conn.fetchval(
            """
            SELECT scoring_config_id FROM trips
            WHERE user_id = $1 AND is_demo = $2 AND scoring_config_id IS NOT NULL
            ORDER BY accepted_seq DESC LIMIT 1
            """,
            user_id,
            demo,
        )
        if config_id is None:
            return Progress(
                user_id=user_id,
                trips_counted=trips_counted,
                baseline_trips_needed=BASELINE_TRIPS,
                baseline_waste_per_mile_usd=None,
                current_waste_per_mile_usd=None,
                improvement_pct=None,
                est_savings_usd=0.0,
                weekly=[],
            )
        base = await conn.fetchrow("SELECT * FROM drive_save_baseline($1, $2, $3)", user_id, config_id, demo)
        this_week = await conn.fetchrow(
            """
            SELECT sum(distance_mi) AS miles, sum(avoidable_usd) AS usd FROM daily_user_metrics
            WHERE user_id = $1 AND scoring_config_id = $2 AND is_demo = $3 AND NOT is_baseline
              AND day >= $4 AND day < $4 + INTERVAL '7 days'
            """,
            user_id,
            config_id,
            demo,
            week,
        )
        days = await conn.fetch(
            "SELECT * FROM drive_save_progress($1, $2, $3, $4, $5)",
            user_id,
            config_id,
            demo,
            week - timedelta(weeks=PROGRESS_WEEKS - 1),
            week + timedelta(days=7),
        )

    baseline = base["baseline_usd_per_mile"]
    miles, usd = this_week["miles"], this_week["usd"]
    current = usd / miles if miles else None
    ready = base["state"] == "ready" and current is not None

    weeks: dict[date, list[Decimal]] = {}
    for d in days:
        totals = weeks.setdefault(_week_start(d["day"]).date(), [Decimal(0), Decimal(0)])
        totals[0] += d["distance_mi"]
        totals[1] += d["avoidable_usd"]

    return Progress(
        user_id=user_id,
        trips_counted=trips_counted,
        baseline_trips_needed=max(BASELINE_TRIPS - base["baseline_trip_count"], 0),
        baseline_waste_per_mile_usd=_float(baseline, 4),
        current_waste_per_mile_usd=_float(current, 4),
        improvement_pct=_float((baseline - current) / baseline * 100, 1) if ready else None,
        est_savings_usd=_float(baseline * miles - usd, 4) if ready else 0.0,
        weekly=[
            WeeklyPoint(week_start=week_start, miles=_float(m, 1), waste_per_mile_usd=_float(u / m if m else 0, 4))
            for week_start, (m, u) in sorted(weeks.items())
        ],
    )


async def leaderboard(user_id: UUID, period: Period) -> Leaderboard:
    crew_id = await db.pool().fetchval("SELECT league_id FROM league_members WHERE user_id = $1", user_id)
    if crew_id is None:
        raise ApiError(404, "not_in_crew", "Create or join a crew to see its leaderboard")
    crew = await get_crew(crew_id)
    now = datetime.now(timezone.utc)
    rows = await db.pool().fetch("SELECT * FROM drive_save_leaderboard($1, $2, $3)", crew_id, now, crew.is_demo)
    return Leaderboard(
        crew_id=crew.crew_id,
        crew_name=crew.name,
        member_count=len(crew.members),
        active=len(crew.members) >= MIN_ACTIVE_MEMBERS,
        period=period,
        generated_at=now,
        standings=[
            Standing(
                rank=r["rank"],
                user_id=r["user_id"],
                nickname=r["nickname"],
                improvement_pct=_float(r["improvement_pct"], 1),
                est_savings_usd=_float(r["est_savings_usd"], 4) or 0.0,
                trips_counted=r["trip_count"],
                state=r["state"],
            )
            for r in rows
        ],
        is_demo=crew.is_demo,
    )
