"""Placeholder trip pricing and progress math.

TODO(stage 3): replace price_trip() with analytics/finance.py from Person 3.
It already follows the agreed model (fuel used x mileage penalty x gas price),
so the iOS app gets realistic receipts before the real model lands.
"""

from collections import defaultdict
from datetime import date, timedelta
from uuid import UUID

import store
from models.trips import Assumption, Projection, Receipt, ReceiptEvent
from models.users import Progress, WeeklyPoint

GAS_PRICE_USD_PER_GAL = 4.284  # EIA weekly US regular gasoline, week of 2026-10-19
PENALTY_CAP_CITY = 0.40  # DOE: aggressive driving costs up to 40% in stop-and-go traffic
PENALTY_CAP_HIGHWAY = 0.30  # DOE: up to 30% at highway speeds
HIGHWAY_AVG_SPEED_MPH = 40
EVENTS_PER_MILE_AT_CAP = 2.0  # team assumption: 2 harsh events per mile = full penalty
DEFAULT_MPG_CITY = 25.0  # used until the user registers a vehicle
DEFAULT_MPG_HWY = 32.0
YEARLY_MILES = 13_476  # FHWA average miles per driver per year
BASELINE_TRIPS = 3

_EIA_URL = "https://www.eia.gov/dnav/pet/pet_pri_gnd_dcus_nus_w.htm"
_DOE_URL = "https://www.fueleconomy.gov/feg/driveHabits.jsp"
_FHWA_URL = "https://www.fhwa.dot.gov/ohim/onh00/bar8.htm"
_SOURCES_CHECKED = date(2026, 10, 24)


def _mpg(user: store.UserRecord, highway: bool) -> tuple[float, str | None]:
    if user.vehicle:
        return (user.vehicle.mpg_hwy if highway else user.vehicle.mpg_city), "https://www.fueleconomy.gov/feg/ws/"
    return (DEFAULT_MPG_HWY if highway else DEFAULT_MPG_CITY), None


def price_trip(record: store.TripRecord) -> Receipt:
    trip = record.trip
    user = store.users[record.user_id]
    highway = trip.avg_speed_mph >= HIGHWAY_AVG_SPEED_MPH
    mpg, mpg_source = _mpg(user, highway)

    fuel_gal = trip.distance_mi / mpg
    fuel_cost = fuel_gal * GAS_PRICE_USD_PER_GAL
    cap = PENALTY_CAP_HIGHWAY if highway else PENALTY_CAP_CITY
    penalty = min(len(trip.events) / trip.distance_mi / EVENTS_PER_MILE_AT_CAP, 1.0) * cap
    avoidable = fuel_cost * penalty

    # Split the avoidable cost across events by kinetic-energy share (v1^2 - v2^2).
    weights = [max(abs(e.speed_before_mph**2 - e.speed_after_mph**2), 1.0) for e in trip.events]
    total_weight = sum(weights) or 1.0
    events = [
        ReceiptEvent(
            type=e.type,
            ts=e.ts,
            speed_before_mph=e.speed_before_mph,
            speed_after_mph=e.speed_after_mph,
            cost_usd=round(avoidable * w / total_weight, 2),
        )
        for e, w in zip(trip.events, weights)
    ]

    return Receipt(
        trip_id=record.trip_id,
        distance_mi=trip.distance_mi,
        fuel_gal=round(fuel_gal, 3),
        fuel_cost_usd=round(fuel_cost, 2),
        avoidable_fuel_usd=round(avoidable, 2),
        events=events,
        projection=Projection(
            yearly_usd=round(avoidable / trip.distance_mi * YEARLY_MILES, 0),
            basis=f"this trip's waste per mile x {YEARLY_MILES:,} mi/yr (FHWA average)",
        ),
        assumptions=[
            Assumption(key="gas_price", value=GAS_PRICE_USD_PER_GAL, unit="USD/gal", source_url=_EIA_URL, as_of=date(2026, 10, 19)),
            Assumption(key="mpg", value=mpg, unit="mi/gal", source_url=mpg_source, as_of=_SOURCES_CHECKED, is_estimate=mpg_source is None),
            Assumption(key="mileage_penalty_cap", value=cap, unit="fraction", source_url=_DOE_URL, as_of=_SOURCES_CHECKED),
            Assumption(key="events_per_mile_at_cap", value=EVENTS_PER_MILE_AT_CAP, unit="events/mi", source_url=None, as_of=_SOURCES_CHECKED, is_estimate=True),
            Assumption(key="yearly_miles", value=YEARLY_MILES, unit="mi/yr", source_url=_FHWA_URL, as_of=_SOURCES_CHECKED),
        ],
    )


def _waste_per_mile(records: list[store.TripRecord]) -> float | None:
    miles = sum(r.trip.distance_mi for r in records)
    if miles == 0:
        return None
    return sum(price_trip(r).avoidable_fuel_usd for r in records) / miles


def progress(user_id: UUID) -> Progress:
    records = sorted((r for r in store.trips.values() if r.user_id == user_id), key=lambda r: r.trip.started_at)
    baseline_records, later = records[:BASELINE_TRIPS], records[BASELINE_TRIPS:]
    baseline = _waste_per_mile(baseline_records) if len(baseline_records) == BASELINE_TRIPS else None
    current = _waste_per_mile(later)

    improvement = None
    savings = 0.0
    if baseline is not None and current is not None:
        improvement = (baseline - current) / baseline * 100 if baseline > 0 else 0.0
        savings = max(baseline - current, 0.0) * sum(r.trip.distance_mi for r in later)

    by_week: dict[date, list[store.TripRecord]] = defaultdict(list)
    for r in records:
        day = r.trip.started_at.date()
        by_week[day - timedelta(days=day.weekday())].append(r)
    weekly = [
        WeeklyPoint(
            week_start=week,
            miles=round(sum(r.trip.distance_mi for r in rs), 1),
            waste_per_mile_usd=round(_waste_per_mile(rs) or 0.0, 4),
        )
        for week, rs in sorted(by_week.items())
    ]

    return Progress(
        user_id=user_id,
        trips_counted=len(records),
        baseline_trips_needed=max(BASELINE_TRIPS - len(records), 0),
        baseline_waste_per_mile_usd=None if baseline is None else round(baseline, 4),
        current_waste_per_mile_usd=None if current is None else round(current, 4),
        improvement_pct=None if improvement is None else round(improvement, 1),
        est_savings_usd=round(savings, 2),
        weekly=weekly,
    )
