from datetime import date
from enum import Enum
from uuid import UUID

from pydantic import AwareDatetime, BaseModel, Field, field_validator, model_validator

MAX_SPEED_MPH = 120
MAX_EVENTS_PER_MINUTE = 10
MAX_TRACE_SECONDS = 60


class EventType(str, Enum):
    harsh_brake = "harsh_brake"
    rapid_accel = "rapid_accel"
    sharp_turn = "sharp_turn"


class SpeedSample(BaseModel):
    t_s: float = Field(ge=-MAX_TRACE_SECONDS, le=MAX_TRACE_SECONDS, description="Seconds from the event's ts; negative = before the event")
    speed_mph: float = Field(ge=0, le=MAX_SPEED_MPH)


class TripEventIn(BaseModel):
    type: EventType
    ts: AwareDatetime
    peak_g: float = Field(gt=0, le=2.0, description="Peak acceleration in g: forward/backward for harsh_brake and rapid_accel, sideways for sharp_turn")
    speed_before_mph: float = Field(ge=0, le=MAX_SPEED_MPH)
    speed_after_mph: float = Field(ge=0, le=MAX_SPEED_MPH)
    duration_s: float | None = Field(default=None, gt=0, le=60, description="How long the event lasted")
    heading_change_deg: float | None = Field(default=None, ge=0, le=360, description="How far the car turned, as an absolute angle; send for sharp_turn")
    speed_trace: list[SpeedSample] = Field(
        min_length=2,
        max_length=241,
        description="Speeds around the event, oldest first: about one per second from 10 s before to 10 s after",
    )
    lat: float | None = Field(default=None, ge=-90, le=90)
    lng: float | None = Field(default=None, ge=-180, le=180)

    @field_validator("speed_trace")
    @classmethod
    def check_trace_surrounds_event(cls, trace: list[SpeedSample]) -> list[SpeedSample]:
        if any(later.t_s <= earlier.t_s for earlier, later in zip(trace, trace[1:])):
            raise ValueError("speed_trace times must increase")
        if trace[0].t_s >= 0 or trace[-1].t_s <= 0:
            raise ValueError("speed_trace must include speeds from before and after the event")
        return trace


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
    events: list[ReceiptEvent]
    avoidable_cost_usd: float = Field(description="Sum of the event costs for this trip")
    cost_model: str = Field(description='Model that produced the dollar amounts; "flat_per_event" ($1 per event) until the real model lands')
    assumptions: list[Assumption]
    is_estimate: bool = True
    is_demo: bool = False
