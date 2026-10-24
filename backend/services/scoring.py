"""Progress math: baselines, improvement and estimated savings per driver.

Dollar amounts come from services/cost_model.py.
"""

from collections import defaultdict
from datetime import date, timedelta
from uuid import UUID

import store
from models.users import Progress, WeeklyPoint
from services import cost_model

BASELINE_TRIPS = 3


def _waste_per_mile(records: list[store.TripRecord]) -> float | None:
    miles = sum(r.trip.distance_mi for r in records)
    if miles == 0:
        return None
    return sum(cost_model.price_trip(r).avoidable_cost_usd for r in records) / miles


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
