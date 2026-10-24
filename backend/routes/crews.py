import secrets
from datetime import datetime, timezone
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, status

import store
from auth import get_current_user
from errors import ApiError
from models.crews import MIN_ACTIVE_MEMBERS, Crew, CrewCreate, CrewJoin, CrewMember

router = APIRouter(tags=["crews"])

# No 0/O or 1/I, so codes are easy to read aloud and type.
_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


def _new_join_code() -> str:
    return "".join(secrets.choice(_CODE_ALPHABET) for _ in range(6))


def _crew_out(crew: store.CrewRecord, viewer_id: UUID) -> Crew:
    members = [
        CrewMember(user_id=uid, nickname=store.users[uid].nickname, joined_at=joined)
        for uid, joined in sorted(crew.members.items(), key=lambda m: m[1])
    ]
    return Crew(
        crew_id=crew.crew_id,
        name=crew.name,
        join_code=crew.join_code if viewer_id in crew.members else None,
        members=members,
        member_count=len(members),
        active=len(members) >= MIN_ACTIVE_MEMBERS,
        is_demo=crew.is_demo,
    )


def _get_crew(crew_id: UUID) -> store.CrewRecord:
    crew = store.crews.get(crew_id)
    if crew is None:
        raise ApiError(404, "crew_not_found", "No crew with that id")
    return crew


@router.post("/crews", response_model=Crew, status_code=status.HTTP_201_CREATED)
async def create_crew(body: CrewCreate, user: store.UserRecord = Depends(get_current_user)) -> Crew:
    crew = store.CrewRecord(crew_id=uuid4(), name=body.name, join_code=_new_join_code())
    crew.members[user.user_id] = datetime.now(timezone.utc)  # the creator joins automatically
    store.crews[crew.crew_id] = crew
    return _crew_out(crew, user.user_id)


@router.post("/crews/{crew_id}/join", response_model=Crew)
async def join_crew(crew_id: UUID, body: CrewJoin, user: store.UserRecord = Depends(get_current_user)) -> Crew:
    crew = _get_crew(crew_id)
    if body.join_code.strip().upper() != crew.join_code:
        raise ApiError(403, "wrong_join_code", "That join code does not match this crew")
    crew.members.setdefault(user.user_id, datetime.now(timezone.utc))  # joining twice is a no-op
    return _crew_out(crew, user.user_id)


@router.get("/crews/{crew_id}", response_model=Crew)
async def get_crew(crew_id: UUID, user: store.UserRecord = Depends(get_current_user)) -> Crew:
    return _crew_out(_get_crew(crew_id), user.user_id)
