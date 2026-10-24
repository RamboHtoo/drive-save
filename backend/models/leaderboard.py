from enum import Enum
from uuid import UUID

from pydantic import AwareDatetime, BaseModel, Field


class Period(str, Enum):
    week = "week"


class Standing(BaseModel):
    rank: int | None = Field(description="1 = most improved (ties share a rank); None while unranked")
    user_id: UUID
    nickname: str
    improvement_pct: float | None = Field(description="(baseline - this week's waste per mile) / baseline x 100; None while unranked")
    est_savings_usd: float = Field(description="Signed estimate for this week's trips; 0 while unranked")
    trips_counted: int = Field(description="This week's trips after the baseline")
    state: str = Field(description="ready, collecting_baseline, zero_baseline or no_weekly_trips")


class Leaderboard(BaseModel):
    """Members of one crew ranked against each other. Crews don't compete with other crews."""

    crew_id: UUID
    crew_name: str
    member_count: int
    active: bool = Field(description="True once the crew has 4 or more members")
    period: Period
    generated_at: AwareDatetime
    standings: list[Standing] = Field(description="Ranked drivers first, then unranked drivers")
    is_demo: bool = False
    is_estimate: bool = True
