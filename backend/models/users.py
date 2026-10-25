from datetime import date
from uuid import UUID

from pydantic import BaseModel, Field

from models.vehicles import Vehicle, VehicleChoice


class UserCreate(BaseModel):
    nickname: str = Field(min_length=1, max_length=32)
    vehicle: VehicleChoice | None = Field(None, description="The driver's car, picked from GET /vehicles/makes, /models and /years")


class UserCreated(BaseModel):
    user_id: UUID
    nickname: str
    token: str = Field(description="Send as 'Authorization: Bearer <token>'. Shown only once.")
    vehicle: Vehicle | None = Field(None, description="The car stored for the driver; GET /users/me/vehicle returns it")


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
