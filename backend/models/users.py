from datetime import date
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field


class UserCreate(BaseModel):
    nickname: str = Field(min_length=1, max_length=32)


class UserCreated(BaseModel):
    user_id: UUID
    nickname: str
    token: str = Field(description="Send as 'Authorization: Bearer <token>'. Shown only once.")


class VehicleIn(BaseModel):
    year: int = Field(ge=1984, le=2027, description="fueleconomy.gov covers model years from 1984")
    make: str = Field(min_length=1, max_length=40)
    model: str = Field(min_length=1, max_length=60)
    # Optional manual override when the fueleconomy.gov lookup fails.
    mpg_city: float | None = Field(default=None, gt=0, le=150)
    mpg_hwy: float | None = Field(default=None, gt=0, le=150)


class VehicleOut(BaseModel):
    year: int
    make: str
    model: str
    mpg_city: float
    mpg_hwy: float
    mpg_source: Literal["fueleconomy.gov", "manual", "mock"]


class WeeklyPoint(BaseModel):
    week_start: date
    miles: float
    waste_per_mile_usd: float


class Progress(BaseModel):
    user_id: UUID
    trips_counted: int
    baseline_trips_needed: int = Field(description="Trips still needed before the baseline is set (baseline = first 3 trips)")
    baseline_waste_per_mile_usd: float | None
    current_waste_per_mile_usd: float | None
    improvement_pct: float | None
    est_savings_usd: float
    weekly: list[WeeklyPoint]
    is_estimate: bool = True
