"""Turns a trip's harsh events into dollars.

build_input() gathers everything the cost model needs: the trip, each event's
speeds, acceleration, duration and turn angle, and the car's specs.
estimate() is the cost model itself. It's a placeholder that charges a flat $1
per harsh event; the analytics teammate replaces its body (or imports their
function here) and keeps the signature CostModelInput -> CostModelOutput.
"""

from datetime import date

import store
from errors import ApiError
from models.cost_model import CostModelInput, CostModelOutput, EventInput, TripInput
from models.trips import Assumption, Receipt, ReceiptEvent

COST_MODEL = "flat_per_event"
COST_PER_EVENT_USD = 1.00
_PLACEHOLDER_SET_ON = date(2026, 10, 24)

_MPS_PER_MPH = 0.44704
_STANDARD_GRAVITY = 9.80665  # m/s^2


def build_input(record: store.TripRecord) -> CostModelInput:
    trip = record.trip
    events = []
    for index, e in enumerate(trip.events):
        change = e.speed_after_mph - e.speed_before_mph
        mean_g = change * _MPS_PER_MPH / e.duration_s / _STANDARD_GRAVITY if e.duration_s else None
        events.append(
            EventInput(
                index=index,
                type=e.type,
                ts=e.ts,
                speed_before_mph=e.speed_before_mph,
                speed_after_mph=e.speed_after_mph,
                speed_change_mph=round(change, 3),
                avg_speed_mph=round((e.speed_before_mph + e.speed_after_mph) / 2, 3),
                duration_s=e.duration_s,
                peak_g=e.peak_g,
                mean_accel_g=None if mean_g is None else round(mean_g, 4),
                heading_change_deg=e.heading_change_deg,
                lat=e.lat,
                lng=e.lng,
            )
        )
    return CostModelInput(
        trip=TripInput(
            trip_id=record.trip_id,
            started_at=trip.started_at,
            ended_at=trip.ended_at,
            duration_s=(trip.ended_at - trip.started_at).total_seconds(),
            distance_mi=trip.distance_mi,
            avg_speed_mph=trip.avg_speed_mph,
        ),
        vehicle=record.vehicle,
        events=events,
    )


def estimate(inputs: CostModelInput) -> CostModelOutput:
    """The cost model. Placeholder: every harsh event costs $1, whatever the inputs say."""
    return CostModelOutput(
        model_name=COST_MODEL,
        event_costs_usd=[COST_PER_EVENT_USD] * len(inputs.events),
        assumptions=[
            Assumption(
                key="cost_per_event",
                value=COST_PER_EVENT_USD,
                unit="USD/event",
                source_url=None,
                as_of=_PLACEHOLDER_SET_ON,
                is_estimate=True,
            ),
        ],
    )


def price_trip(record: store.TripRecord) -> Receipt:
    inputs = build_input(record)
    result = estimate(inputs)
    if len(result.event_costs_usd) != len(inputs.events):
        raise ApiError(500, "cost_model_error", "The cost model must return one cost per event")
    events = [
        ReceiptEvent(
            type=e.type,
            ts=e.ts,
            speed_before_mph=e.speed_before_mph,
            speed_after_mph=e.speed_after_mph,
            cost_usd=round(cost, 2),
        )
        for e, cost in zip(inputs.events, result.event_costs_usd)
    ]
    return Receipt(
        trip_id=record.trip_id,
        distance_mi=inputs.trip.distance_mi,
        events=events,
        avoidable_cost_usd=round(sum(result.event_costs_usd), 2),
        cost_model=result.model_name,
        assumptions=result.assumptions,
    )
