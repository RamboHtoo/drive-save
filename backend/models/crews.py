from uuid import UUID

from pydantic import AwareDatetime, BaseModel, Field

# Mystery Stack requires groups of 4 or more; smaller crews are not ranked.
MIN_ACTIVE_MEMBERS = 4


class CrewCreate(BaseModel):
    name: str = Field(min_length=1, max_length=40)


class CrewJoin(BaseModel):
    join_code: str = Field(min_length=4, max_length=12)


class CrewMember(BaseModel):
    user_id: UUID
    nickname: str
    joined_at: AwareDatetime


class Crew(BaseModel):
    crew_id: UUID
    name: str
    join_code: str | None = Field(description="Only returned to crew members")
    members: list[CrewMember]
    member_count: int
    active: bool = Field(description=f"True once the crew has {MIN_ACTIVE_MEMBERS} or more members")
    is_demo: bool = False
