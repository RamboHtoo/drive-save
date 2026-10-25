"""Database access for the API (Tiger Data: Postgres + TimescaleDB).

Tables and analytics functions come from analytics/schema.sql and
analytics/queries.sql (schema v4, owned by the data teammate), plus
backend/db/002_event_details.sql. The rules for uploads, baselines and metrics
follow docs/database-setup.md. The API's crews are the schema's leagues: tables
leagues and league_members, column league_id.
"""

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
from services import cost_model

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


async def create_user(nickname: str, token_hash: str) -> UUID:
    return await db.pool().fetchval("INSERT INTO users (nickname, token_hash) VALUES ($1, $2) RETURNING id", nickname, token_hash)


async def user_by_token_hash(token_hash: str) -> User | None:
    row = await db.pool().fetchrow("SELECT id, nickname, vehicle FROM users WHERE token_hash = $1", token_hash)
    return User(row["id"], row["nickname"], row["vehicle"]) if row else None


async def set_vehicle(user_id: UUID, vehicle: dict[str, JsonValue]) -> None:
    await db.pool().execute("UPDATE users SET vehicle = $2 WHERE id = $1", user_id, vehicle)


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
                crew_id = await conn.fetchval("INSERT INTO leagues (name, join_code) VALUES ($1, $2) RETURNING id", name, new_join_code())
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

        result = cost_model.estimate(cost_model.build_input(cost_model.PricingRequest(trip_id, trip, user.vehicle)))
        if len(result.event_costs_usd) != len(trip.events):
            raise ApiError(500, "cost_model_error", "The cost model must return one cost per event")
        scored = result.fuel_gal is not None

        await conn.executemany(
            """
            INSERT INTO trip_events (ts, event_id, trip_id, type, peak_g, speed_before_mph, speed_after_mph,
                                     detector_version, cost_usd, duration_s, heading_change_deg)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
            """,
            [
                (e.ts, e.event_id, trip_id, e.type.value, e.peak_g, e.speed_before_mph, e.speed_after_mph,
                 e.detector_version, _dec(cost) if scored else None, e.duration_s, e.heading_change_deg)
                for e, cost in zip(trip.events, result.event_costs_usd)
            ],
        )
        await conn.executemany(
            "INSERT INTO speed_samples (ts, trip_id, sample_seq, speed_mps, speed_accuracy_mps) VALUES ($1, $2, $3, $4, $5)",
            [(s.ts, trip_id, s.sample_seq, s.speed_mps, s.speed_accuracy_mps) for s in trip.speed_samples],
        )

        if scored:
            await _record_score(conn, user, trip, trip_id, result)
        else:
            await conn.execute("UPDATE trips SET status = 'insufficient_data' WHERE id = $1", trip_id)
    return trip_id, False


async def _scoring_config(conn: asyncpg.Connection, result: CostModelOutput, vehicle: dict[str, JsonValue] | None) -> UUID:
    """Configurations are immutable: reuse an identical one or insert a new one."""
    args = (
        result.model_name,
        vehicle or {},
        _dec(cost_model.US_AVERAGE_FUEL_PRICE.value),
        [a.model_dump(mode="json") for a in result.assumptions],
    )
    existing = await conn.fetchval(
        """
        SELECT id FROM scoring_configs
        WHERE model_version = $1 AND vehicle_profile = $2 AND fuel_price_usd_per_gal = $3 AND assumptions = $4
        ORDER BY created_at, id LIMIT 1
        """,
        *args,
    )
    if existing:
        return existing
    return await conn.fetchval(
        "INSERT INTO scoring_configs (model_version, vehicle_profile, fuel_price_usd_per_gal, assumptions) VALUES ($1, $2, $3, $4) RETURNING id",
        *args,
    )


async def _record_score(conn: asyncpg.Connection, user: User, trip: TripCreate, trip_id: UUID, result: CostModelOutput) -> None:
    config_id = await _scoring_config(conn, result, user.vehicle)
    avoidable = sum(result.event_costs_usd)

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
        "UPDATE trips SET status = 'scored', scoring_config_id = $2, fuel_gal = $3, avoidable_usd = $4, baseline_slot = $5 WHERE id = $1",
        trip_id,
        config_id,
        _dec(result.fuel_gal),
        _dec(avoidable),
        slot,
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
        SELECT t.user_id, t.status, t.distance_mi, t.avoidable_usd, t.is_demo,
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
            raise ApiError(409, "trip_not_scored", "This trip doesn't have enough data to price")
        events = await conn.fetch(
            "SELECT type, ts, speed_before_mph, speed_after_mph, cost_usd FROM trip_events WHERE trip_id = $1 ORDER BY ts, event_id",
            trip_id,
        )
    return Receipt(
        trip_id=trip_id,
        distance_mi=float(t["distance_mi"]),
        events=[
            ReceiptEvent(
                type=e["type"],
                ts=e["ts"],
                speed_before_mph=e["speed_before_mph"],
                speed_after_mph=e["speed_after_mph"],
                cost_usd=_float(e["cost_usd"], 2),
            )
            for e in events
        ],
        avoidable_cost_usd=_float(t["avoidable_usd"], 2),
        cost_model=t["model_version"],
        assumptions=[Assumption(**a) for a in t["assumptions"]],
        is_demo=t["is_demo"],
    )


async def cost_input(trip_id: UUID, user_id: UUID) -> CostModelInput:
    async with db.pool().acquire() as conn:
        t = await _owned_trip(conn, trip_id, user_id)
        trip = await _load_trip(conn, trip_id)
    vehicle = t["vehicle_profile"] or None  # an empty profile means the driver hadn't sent a car
    return cost_model.build_input(cost_model.PricingRequest(trip_id, trip, vehicle))


# ---- Progress and leaderboard -----------------------------------------------------------------


async def progress(user_id: UUID) -> Progress:
    week = _week_start(datetime.now(timezone.utc))
    async with db.pool().acquire() as conn:
        trips_counted = await conn.fetchval("SELECT count(*) FROM trips WHERE user_id = $1 AND NOT is_demo", user_id)
        config_id = await conn.fetchval(
            """
            SELECT scoring_config_id FROM trips
            WHERE user_id = $1 AND NOT is_demo AND scoring_config_id IS NOT NULL
            ORDER BY accepted_seq DESC LIMIT 1
            """,
            user_id,
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
        base = await conn.fetchrow("SELECT * FROM drive_save_baseline($1, $2, false)", user_id, config_id)
        this_week = await conn.fetchrow(
            """
            SELECT sum(distance_mi) AS miles, sum(avoidable_usd) AS usd FROM daily_user_metrics
            WHERE user_id = $1 AND scoring_config_id = $2 AND NOT is_demo AND NOT is_baseline
              AND day >= $3 AND day < $3 + INTERVAL '7 days'
            """,
            user_id,
            config_id,
            week,
        )
        days = await conn.fetch(
            "SELECT * FROM drive_save_progress($1, $2, false, $3, $4)",
            user_id,
            config_id,
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
        est_savings_usd=_float(baseline * miles - usd, 2) if ready else 0.0,
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
                est_savings_usd=_float(r["est_savings_usd"], 2) or 0.0,
                trips_counted=r["trip_count"],
                state=r["state"],
            )
            for r in rows
        ],
        is_demo=crew.is_demo,
    )
