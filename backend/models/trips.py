from datetime import date
from enum import Enum
from typing import Literal
from uuid import UUID

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, field_validator, model_validator

MAX_SPEED_MPH = 120
MAX_SPEED_MPS = 53.6448  # 120 mph
MAX_EVENTS_PER_MINUTE = 10
MAX_SPEED_SAMPLES = 21_600  # 6 hours at one reading per second


class StrictModel(BaseModel):
    """Rejects NaN and infinity in every number."""

    model_config = ConfigDict(allow_inf_nan=False)


class EventType(str, Enum):
    harsh_brake = "harsh_brake"
    rapid_accel = "rapid_accel"
    sharp_turn = "sharp_turn"


class SpeedSample(StrictModel):
    """One GPS speed reading. Invalid readings (iOS reports -1) are kept as null."""

    ts: AwareDatetime = Field(description="When the reading was taken (UTC)")
    sample_seq: int = Field(ge=0, description="Unique within the trip, e.g. a counter")
    speed_mps: float | None = Field(default=None, description="CLLocation.speed in m/s")
    speed_accuracy_mps: float | None = Field(default=None, description="CLLocation.speedAccuracy in m/s")

    @field_validator("speed_mps")
    @classmethod
    def drop_invalid_speed(cls, value: float | None) -> float | None:
        return None if value is None or value < 0 or value > MAX_SPEED_MPS else value

    @field_validator("speed_accuracy_mps")
    @classmethod
    def drop_invalid_accuracy(cls, value: float | None) -> float | None:
        return None if value is None or value < 0 else value


class TripEventIn(StrictModel):
    event_id: UUID = Field(description="Generated on the phone; stays the same when the trip is re-uploaded")
    type: EventType
    ts: AwareDatetime
    detector_version: str = Field(min_length=1, max_length=64, description='Version of the phone\'s event detector, e.g. "ios-0.1.0"')
    peak_g: float = Field(gt=0, le=2.0, description="Peak acceleration in g: forward/backward for harsh_brake and rapid_accel, sideways for sharp_turn")
    speed_before_mph: float = Field(ge=0, le=MAX_SPEED_MPH)
    speed_after_mph: float = Field(ge=0, le=MAX_SPEED_MPH)
    duration_s: float | None = Field(default=None, gt=0, le=60, description="How long the event lasted")
    heading_change_deg: float | None = Field(default=None, ge=0, le=360, description="How far the car turned, as an absolute angle; send for sharp_turn")


class TripCreate(StrictModel):
    """Trip summary, the events the phone detected, and its GPS speed readings. The client never sends dollar amounts."""

    client_trip_id: UUID = Field(description="Generated on the phone; makes retried uploads idempotent")
    started_at: AwareDatetime
    ended_at: AwareDatetime
    distance_mi: float = Field(gt=0, le=1000)
    avg_speed_mph: float = Field(ge=0, le=MAX_SPEED_MPH)
    source: Literal["recorded", "replayed", "synthetic"] = Field(default="recorded", description="Replayed and synthetic trips must be demo trips")
    is_demo: bool = False
    events_complete: bool = Field(default=False, description="True only when the phone's detector ran for the whole trip, so events lists every harsh moment")
    detector_version: str | None = Field(
        default=None, min_length=1, max_length=64, pattern=r"\S", description='Version of the detector that ran for the trip, e.g. "ios-0.1.0"'
    )
    events: list[TripEventIn] = Field(default_factory=list)
    speed_samples: list[SpeedSample] = Field(
        default_factory=list,
        max_length=MAX_SPEED_SAMPLES,
        description="GPS speed readings, about one per second; should cover 10 s before and after every event",
    )

    @model_validator(mode="after")
    def check_trip(self) -> "TripCreate":
        if self.ended_at <= self.started_at:
            raise ValueError("ended_at must be after started_at")
        if self.source != "recorded" and not self.is_demo:
            raise ValueError("replayed and synthetic trips must set is_demo to true")
        for event in self.events:
            if not self.started_at <= event.ts <= self.ended_at:
                raise ValueError(f"event at {event.ts.isoformat()} is outside the trip window")
        if len({e.event_id for e in self.events}) != len(self.events):
            raise ValueError("event_id values must be unique within the trip")
        if self.detector_version is not None and any(e.detector_version != self.detector_version for e in self.events):
            raise ValueError("every event's detector_version must match the trip's detector_version")
        minutes = (self.ended_at - self.started_at).total_seconds() / 60
        if len(self.events) > max(minutes, 1) * MAX_EVENTS_PER_MINUTE:
            raise ValueError(f"more than {MAX_EVENTS_PER_MINUTE} events per minute")
        for sample in self.speed_samples:
            if not self.started_at <= sample.ts <= self.ended_at:
                raise ValueError(f"speed sample {sample.sample_seq} is outside the trip window")
        if len({s.sample_seq for s in self.speed_samples}) != len(self.speed_samples):
            raise ValueError("sample_seq values must be unique within the trip")
        if self.events and all(s.speed_mps is None for s in self.speed_samples):
            raise ValueError("speed_samples are required when the trip has events")
        # Canonical form, matching what the database stores, so identical retries compare equal.
        self.distance_mi = round(self.distance_mi, 6)
        self.events.sort(key=lambda e: (e.ts, e.event_id))
        self.speed_samples.sort(key=lambda s: (s.ts, s.sample_seq))
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
    avoidable_cost_usd: float = Field(description="Avoidable cost of the trip: its priced events plus any driving above 65 mph")
    high_speed_cost_usd: float | None = Field(default=None, description="The part of avoidable_cost_usd from driving above 65 mph")
    cost_model: str = Field(description="Version of the model that produced the amounts")
    label: str | None = Field(default=None, description="Wording to show with the amounts")
    assumptions: list[Assumption] = Field(description="Every numeric constant and data source the model used")
    notes: list[str] = Field(default_factory=list, description="Assumptions that aren't numbers, such as the road conditions")
    is_estimate: bool = True
    is_demo: bool = False
