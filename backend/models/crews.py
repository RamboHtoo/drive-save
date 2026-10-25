from uuid import UUID

from pydantic import AwareDatetime, BaseModel, Field

from models.common import display_name

# Mystery Stack requires groups of 4 or more; smaller crews are not ranked.
MIN_ACTIVE_MEMBERS = 4


class CrewCreate(BaseModel):
    name: display_name(40) = Field(description="Stored without surrounding spaces")


class CrewJoin(BaseModel):
    join_code: str = Field(min_length=4, max_length=12)


class CrewMember(BaseModel):
    user_id: UUID
    nickname: str
    joined_at: AwareDatetime


class Crew(BaseModel):
    crew_id: UUID
    name: str
    join_code: str = Field(description="Crews are only returned to their members")
    members: list[CrewMember]
    member_count: int
    active: bool = Field(description=f"True once the crew has {MIN_ACTIVE_MEMBERS} or more members")
    is_demo: bool = False
