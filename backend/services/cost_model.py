"""Turns a trip's harsh events into dollars.

build_input() gathers everything the cost model needs: the trip and its GPS
speed readings, each event's speeds, acceleration, duration, turn angle and the
readings from 10 s before to 10 s after it, the car's data exactly as the app
sent it, and the fuel price.
estimate() is the cost model itself. It's a placeholder that charges a flat $1
per harsh event; the analytics teammate replaces its body (or imports their
function here) and keeps the signature CostModelInput -> CostModelOutput.
"""

from bisect import bisect_left, bisect_right
from datetime import date, timedelta

import store
from errors import ApiError
from models.cost_model import CostModelInput, CostModelOutput, EventInput, TripInput
from models.trips import Assumption, Receipt, ReceiptEvent

COST_MODEL = "flat_per_event"
COST_PER_EVENT_USD = 1.00
_PLACEHOLDER_SET_ON = date(2026, 10, 24)

# EIA weekly US average retail price, regular gasoline. Update when EIA publishes a new week.
US_AVERAGE_FUEL_PRICE = Assumption(
    key="fuel_price",
    value=4.284,
    unit="USD/gal",
    source_url="https://www.eia.gov/dnav/pet/pet_pri_gnd_dcus_nus_w.htm",
    as_of=date(2026, 10, 19),
)

EVENT_WINDOW = timedelta(seconds=10)  # readings handed to the model before and after each event
_MPS_PER_MPH = 0.44704
_STANDARD_GRAVITY = 9.80665  # m/s^2


def build_input(record: store.TripRecord) -> CostModelInput:
    trip = record.trip
    samples = trip.speed_samples  # sorted by time during validation
    times = [s.ts for s in samples]
    events = []
    for index, e in enumerate(trip.events):
        change = e.speed_after_mph - e.speed_before_mph
        mean_g = change * _MPS_PER_MPH / e.duration_s / _STANDARD_GRAVITY if e.duration_s else None
        around = samples[bisect_left(times, e.ts - EVENT_WINDOW) : bisect_right(times, e.ts + EVENT_WINDOW)]
        valid_times = [s.ts for s in around if s.speed_mps is not None]
        events.append(
            EventInput(
                index=index,
                event_id=e.event_id,
                type=e.type,
                ts=e.ts,
                detector_version=e.detector_version,
                speed_before_mph=e.speed_before_mph,
                speed_after_mph=e.speed_after_mph,
                speed_change_mph=round(change, 3),
                avg_speed_mph=round((e.speed_before_mph + e.speed_after_mph) / 2, 3),
                duration_s=e.duration_s,
                peak_g=e.peak_g,
                mean_accel_g=None if mean_g is None else round(mean_g, 4),
                heading_change_deg=e.heading_change_deg,
                speed_samples=around,
                speed_window_complete=any(t < e.ts for t in valid_times) and any(t > e.ts for t in valid_times),
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
            speed_samples=samples,
        ),
        vehicle=record.vehicle,
        fuel_price=US_AVERAGE_FUEL_PRICE,
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
        is_demo=record.trip.is_demo,
    )
