"""What the backend hands the cost model and what it gets back.

services/cost_model.py builds a CostModelInput for every trip, prices it with
the data teammate's Mazda5 model (drive_save_model), and returns a
CostModelOutput that the backend stores and turns into the receipt. See
docs/cost-model.md.
"""

from typing import Literal
from uuid import UUID

from pydantic import AwareDatetime, BaseModel, Field, JsonValue

from models.trips import Assumption, EventType, SpeedSample


class TripInput(BaseModel):
    trip_id: UUID
    started_at: AwareDatetime
    ended_at: AwareDatetime
    duration_s: float
    distance_mi: float
    avg_speed_mph: float
    source: str
    is_demo: bool
    events_complete: bool = Field(description="True only when the phone's detector ran for the whole trip")
    detector_version: str | None
    speed_samples: list[SpeedSample] = Field(description="Every GPS speed reading the phone sent, in time order")


class EventInput(BaseModel):
    index: int = Field(description="Position in the trip; the output costs use the same order")
    event_id: UUID
    type: EventType
    ts: AwareDatetime
    detector_version: str
    speed_before_mph: float
    speed_after_mph: float
    speed_change_mph: float = Field(description="speed_after - speed_before; negative while slowing down")
    avg_speed_mph: float = Field(description="Mean of speed_before and speed_after: the speed during the event")
    duration_s: float | None
    peak_g: float = Field(description="Forward/backward for harsh_brake and rapid_accel, sideways for sharp_turn")
    mean_accel_g: float | None = Field(description="speed_change / duration in g; negative while slowing; None without duration_s")
    heading_change_deg: float | None = Field(description="How far the car turned; sent for sharp_turn")
    speed_samples: list[SpeedSample] = Field(description="GPS readings from 10 s before to 10 s after the event, in time order")
    speed_window_complete: bool = Field(description="True when there are valid readings both before and after the event")


class CostModelInput(BaseModel):
    trip: TripInput
    vehicle: dict[str, JsonValue] = Field(
        description="The vehicle profile the trip is priced with: the driver's car from the vehicle list with its own parameters, "
        "or the model's 2012 Mazda5 when they have none the model supports"
    )
    fuel_price: Assumption = Field(description="US average retail price of the car's fuel: regular gasoline, or on-highway diesel for a diesel car")
    events: list[EventInput]


class CostModelOutput(BaseModel):
    model_name: str = Field(description="Model version, shown on the receipt as cost_model")
    status: Literal["scored", "insufficient_data"]
    event_costs_usd: list[float | None] = Field(description="One cost per input event, in the same order; null when the trip isn't priced")
    fuel_gal: float | None = Field(description="Fuel budget for the trip from label MPG; the database requires it for scored trips")
    avoidable_usd: float | None = Field(description="Avoidable cost of the trip: its priced events plus driving above 65 mph")
    quality_flags: list[str] = Field(description="Caveats for a priced trip, or why the trip couldn't be priced")
    details: dict[str, JsonValue] | None = Field(description="The model's full result, stored with the trip as model_result")
