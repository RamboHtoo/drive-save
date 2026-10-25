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
from dataclasses import dataclass
from datetime import date, timedelta
from uuid import UUID

from pydantic import JsonValue

from models.cost_model import CostModelInput, CostModelOutput, EventInput, TripInput
from models.trips import Assumption, TripCreate

COST_MODEL = "flat_per_event"
COST_PER_EVENT_USD = 1.00
# The database needs fuel used for every scored trip; until the real model lands, assume 25 mpg.
PLACEHOLDER_MPG = 25.0
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


@dataclass
class PricingRequest:
    trip_id: UUID
    trip: TripCreate
    vehicle: dict[str, JsonValue] | None  # as the app sent it, when the trip was uploaded


def build_input(request: PricingRequest) -> CostModelInput:
    trip = request.trip
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
            trip_id=request.trip_id,
            started_at=trip.started_at,
            ended_at=trip.ended_at,
            duration_s=(trip.ended_at - trip.started_at).total_seconds(),
            distance_mi=trip.distance_mi,
            avg_speed_mph=trip.avg_speed_mph,
            events_complete=trip.events_complete,
            detector_version=trip.detector_version,
            speed_samples=samples,
        ),
        vehicle=request.vehicle,
        fuel_price=US_AVERAGE_FUEL_PRICE,
        events=events,
    )


def estimate(inputs: CostModelInput) -> CostModelOutput:
    """The cost model. Placeholder: every harsh event costs $1, and the car is assumed to get 25 mpg."""
    return CostModelOutput(
        model_name=COST_MODEL,
        event_costs_usd=[COST_PER_EVENT_USD] * len(inputs.events),
        fuel_gal=round(inputs.trip.distance_mi / PLACEHOLDER_MPG, 6),
        assumptions=[
            Assumption(key="cost_per_event", value=COST_PER_EVENT_USD, unit="USD/event", source_url=None, as_of=_PLACEHOLDER_SET_ON, is_estimate=True),
            Assumption(key="placeholder_mpg", value=PLACEHOLDER_MPG, unit="mi/gal", source_url=None, as_of=_PLACEHOLDER_SET_ON, is_estimate=True),
        ],
    )
