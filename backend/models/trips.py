from datetime import date
from enum import Enum
from uuid import UUID

from pydantic import AwareDatetime, BaseModel, Field, model_validator

MAX_SPEED_MPH = 120
MAX_EVENTS_PER_MINUTE = 10


class EventType(str, Enum):
    harsh_brake = "harsh_brake"
    rapid_accel = "rapid_accel"
    sharp_turn = "sharp_turn"


class TripEventIn(BaseModel):
    type: EventType
    ts: AwareDatetime
    peak_g: float = Field(gt=0, le=2.0)
    speed_before_mph: float = Field(ge=0, le=MAX_SPEED_MPH)
    speed_after_mph: float = Field(ge=0, le=MAX_SPEED_MPH)
    lat: float | None = Field(default=None, ge=-90, le=90)
    lng: float | None = Field(default=None, ge=-180, le=180)


class TripCreate(BaseModel):
    """Trip summary plus the events the phone detected. The client never sends dollar amounts."""

    client_trip_id: UUID = Field(description="Generated on the phone; makes retried uploads idempotent")
    started_at: AwareDatetime
    ended_at: AwareDatetime
    distance_mi: float = Field(gt=0, le=1000)
    avg_speed_mph: float = Field(ge=0, le=MAX_SPEED_MPH)
    events: list[TripEventIn] = Field(default_factory=list)

    @model_validator(mode="after")
    def check_events_fit_trip(self) -> "TripCreate":
        if self.ended_at <= self.started_at:
            raise ValueError("ended_at must be after started_at")
        for event in self.events:
            if not self.started_at <= event.ts <= self.ended_at:
                raise ValueError(f"event at {event.ts.isoformat()} is outside the trip window")
        minutes = (self.ended_at - self.started_at).total_seconds() / 60
        if len(self.events) > max(minutes, 1) * MAX_EVENTS_PER_MINUTE:
            raise ValueError(f"more than {MAX_EVENTS_PER_MINUTE} events per minute")
        return self


class TripCreated(BaseModel):
    trip_id: UUID
    receipt_url: str
    duplicate: bool = Field(description="True when this client_trip_id was already uploaded")


class ReceiptEvent(BaseModel):
    type: EventType
    ts: AwareDatetime
    speed_before_mph: float
    speed_after_mph: float
    cost_usd: float


class Projection(BaseModel):
    yearly_usd: float
    basis: str


class Assumption(BaseModel):
    key: str
    value: float
    unit: str
    source_url: str | None
    as_of: date
    is_estimate: bool = Field(default=False, description="True for team assumptions rather than published figures")


class Receipt(BaseModel):
    trip_id: UUID
    distance_mi: float
    fuel_gal: float
    fuel_cost_usd: float
    avoidable_fuel_usd: float
    events: list[ReceiptEvent]
    projection: Projection
    assumptions: list[Assumption]
    is_estimate: bool = True
    is_demo: bool = False
