from enum import Enum
from uuid import UUID

from pydantic import AwareDatetime, BaseModel, Field


class Scope(str, Enum):
    crews = "crews"  # crew vs crew
    members = "members"  # members inside one crew; requires crew_id


class Period(str, Enum):
    week = "week"


class Standing(BaseModel):
    rank: int
    id: UUID = Field(description="crew_id for scope=crews, user_id for scope=members")
    name: str
    members: int | None = Field(default=None, description="Member count; only for scope=crews")
    improvement_pct: float = Field(description="(baseline - this week's waste per mile) / baseline x 100")
    est_savings_usd: float
    is_demo: bool = False


class Leaderboard(BaseModel):
    scope: Scope
    period: Period
    crew_id: UUID | None = None
    generated_at: AwareDatetime
    standings: list[Standing]
    is_estimate: bool = True
