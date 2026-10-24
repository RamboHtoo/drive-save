"""Turns a trip's harsh events into dollars.

Placeholder: every harsh event (harsh_brake, rapid_accel, sharp_turn) costs a
flat $1. The real cost model is being built by another teammate; when it lands,
replace the body of price_trip() and keep the Receipt shape so iOS doesn't break.
"""

from datetime import date

import store
from models.trips import Assumption, Receipt, ReceiptEvent

COST_MODEL = "flat_per_event"
COST_PER_EVENT_USD = 1.00
_PLACEHOLDER_SET_ON = date(2026, 10, 24)


def price_trip(record: store.TripRecord) -> Receipt:
    trip = record.trip
    events = [
        ReceiptEvent(
            type=e.type,
            ts=e.ts,
            speed_before_mph=e.speed_before_mph,
            speed_after_mph=e.speed_after_mph,
            cost_usd=COST_PER_EVENT_USD,
        )
        for e in trip.events
    ]
    return Receipt(
        trip_id=record.trip_id,
        distance_mi=trip.distance_mi,
        events=events,
        avoidable_cost_usd=round(COST_PER_EVENT_USD * len(events), 2),
        cost_model=COST_MODEL,
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
