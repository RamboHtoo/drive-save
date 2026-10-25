import secrets
from uuid import UUID

from fastapi import APIRouter, Depends, status

import repo
from auth import get_current_user
from errors import ApiError
from models.crews import MIN_ACTIVE_MEMBERS, Crew, CrewCreate, CrewJoin, CrewMember

router = APIRouter(tags=["crews"])

# No 0/O or 1/I, so codes are easy to read aloud and type.
_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


def _new_join_code() -> str:
    return "".join(secrets.choice(_CODE_ALPHABET) for _ in range(6))


def _crew_out(crew: repo.Crew) -> Crew:
    return Crew(
        crew_id=crew.crew_id,
        name=crew.name,
        join_code=crew.join_code,
        members=[CrewMember(user_id=m.user_id, nickname=m.nickname, joined_at=m.joined_at) for m in crew.members],
        member_count=len(crew.members),
        active=len(crew.members) >= MIN_ACTIVE_MEMBERS,
        is_demo=crew.is_demo,
    )


async def _get_crew(crew_id: UUID) -> repo.Crew:
    crew = await repo.get_crew(crew_id)
    if crew is None:
        raise ApiError(404, "crew_not_found", "No crew with that id")
    return crew


@router.post("/crews", response_model=Crew, status_code=status.HTTP_201_CREATED)
async def create_crew(body: CrewCreate, user: repo.User = Depends(get_current_user)) -> Crew:
    crew_id = await repo.create_crew(body.name, user.user_id, _new_join_code)  # the creator joins automatically
    return _crew_out(await _get_crew(crew_id))


@router.post("/crews/{crew_id}/join", response_model=Crew)
async def join_crew(crew_id: UUID, body: CrewJoin, user: repo.User = Depends(get_current_user)) -> Crew:
    crew = await _get_crew(crew_id)
    if body.join_code.strip().upper() != crew.join_code:
        raise ApiError(403, "wrong_join_code", "That join code does not match this crew")
    await repo.join_crew(crew_id, user.user_id)  # moves the driver out of any other crew
    return _crew_out(await _get_crew(crew_id))


@router.get("/crews/{crew_id}", response_model=Crew)
async def get_crew(crew_id: UUID, user: repo.User = Depends(get_current_user)) -> Crew:
    crew = await _get_crew(crew_id)
    if not any(m.user_id == user.user_id for m in crew.members):
        raise ApiError(403, "forbidden", "You can only view a crew you belong to")
    return _crew_out(crew)
