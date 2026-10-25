"""Prices a trip with the data teammate's Mazda5 fuel model (drive_save_model).

build_input() gathers everything about the trip: the trip and its GPS speed
readings, each event's speeds, acceleration, duration, turn angle and the
readings from 10 s before to 10 s after it, the vehicle profile and the fuel
price. estimate() hands that to drive_save_model.estimate_trip and returns the
result in the shape the database stores. See docs/cost-model.md.

The model is experimental. It supports one car, a 2012 Mazda5, and its results
may only be shown as demo data, which the shared schema enforces. So every trip
is priced as that car, and every crew and trip is stored as demo (DEMO_ONLY).
"""

from bisect import bisect_left, bisect_right
from dataclasses import dataclass
from datetime import date, timedelta
from uuid import UUID

from drive_save_model import estimate_trip, scoring_config
from pydantic import JsonValue

from models.cost_model import CostModelInput, CostModelOutput, EventInput, TripInput
from models.trips import Assumption, TripCreate

# EIA weekly US average retail price, regular gasoline. Update when EIA publishes a new week;
# a new price makes a new scoring configuration, so every driver's baseline starts again.
US_AVERAGE_FUEL_PRICE = Assumption(
    key="fuel_price",
    value=4.284,
    unit="USD/gal",
    source_url="https://www.eia.gov/dnav/pet/pet_pri_gnd_dcus_nus_w.htm",
    as_of=date(2026, 10, 19),
)
# The model's immutable configuration: version, Mazda5 profile, price and every assumption, with an id derived from them.
SCORING_CONFIG = scoring_config(
    US_AVERAGE_FUEL_PRICE.value,
    price_as_of=US_AVERAGE_FUEL_PRICE.as_of.isoformat(),
    price_source_url=US_AVERAGE_FUEL_PRICE.source_url,
)
DEMO_ONLY = True  # the schema accepts experimental results only on demo trips (trips_math_model_demo_only)

EVENT_WINDOW = timedelta(seconds=10)  # readings included with each event before and after it
_MPS_PER_MPH = 0.44704
_STANDARD_GRAVITY = 9.80665  # m/s^2


@dataclass
class PricingRequest:
    trip_id: UUID
    trip: TripCreate
    vehicle: dict[str, JsonValue]  # the vehicle profile the trip is priced with


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
            source=trip.source,
            is_demo=trip.is_demo,
            events_complete=trip.events_complete,
            detector_version=trip.detector_version,
            speed_samples=samples,
        ),
        vehicle=request.vehicle,
        fuel_price=US_AVERAGE_FUEL_PRICE,
        events=events,
    )


def estimate(inputs: CostModelInput) -> CostModelOutput:
    """Runs the Mazda5 model. A trip it can't price comes back as insufficient_data, with the reason in quality_flags."""
    trip = inputs.trip
    result = estimate_trip(
        vehicle_profile=inputs.vehicle,
        speed_samples=[s.model_dump() for s in trip.speed_samples],
        trip_metadata={
            "started_at": trip.started_at,
            "ended_at": trip.ended_at,
            "distance_mi": trip.distance_mi,
            "source": trip.source,
            "is_demo": trip.is_demo,
            "events_complete": trip.events_complete,
            "detector_version": trip.detector_version,
        },
        scoring_config=SCORING_CONFIG,
        events=[
            {
                "event_id": str(e.event_id),
                "ts": e.ts,
                "duration_s": e.duration_s,
                "type": e.type.value,
                "peak_g": e.peak_g,
                "speed_before_mph": e.speed_before_mph,
                "speed_after_mph": e.speed_after_mph,
                "detector_version": e.detector_version,
            }
            for e in inputs.events
        ],
    )
    details = result["model_details"]
    costs = {e["event_id"]: e["cost_usd"] for e in details.get("events", [])}
    return CostModelOutput(
        model_name=SCORING_CONFIG["model_version"],
        status=result["status"],
        event_costs_usd=[costs.get(str(e.event_id)) for e in inputs.events],
        fuel_gal=result["fuel_gal"],
        avoidable_usd=result["avoidable_usd"],
        quality_flags=result["quality_flags"],
        details=details if trip.is_demo else None,  # the schema stores experimental results only on demo trips
    )
