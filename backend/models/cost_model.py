"""The contract between the backend and the cost model (owned by the analytics teammate).

The backend builds a CostModelInput for every trip, the model returns a
CostModelOutput, and the backend turns that into the receipt. See docs/cost-model.md.
"""

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
    vehicle: dict[str, JsonValue] | None = Field(
        description="The car's data exactly as the app sent it (PUT /users/me/vehicle), as of the trip's upload; None if it never sent one"
    )
    fuel_price: Assumption = Field(description="US average retail regular gasoline price; list it in your assumptions")
    events: list[EventInput]


class CostModelOutput(BaseModel):
    model_name: str = Field(description="Shown on the receipt as cost_model")
    event_costs_usd: list[float] = Field(description="Exactly one cost per input event, in the same order")
    fuel_gal: float | None = Field(default=None, description="Fuel the whole trip used; the database requires it for scored trips")
    assumptions: list[Assumption] = Field(description="Every constant and data source the model used")
