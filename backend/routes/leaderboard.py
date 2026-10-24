"""Drivers compete against each other inside their crew; the leaderboard ranks the caller's crew."""

from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends

import store
from auth import get_current_user
from errors import ApiError
from models.crews import MIN_ACTIVE_MEMBERS
from models.leaderboard import Leaderboard, Period, Standing
from services import scoring

router = APIRouter(tags=["leaderboard"])


def _standing(user_id: UUID) -> Standing:
    p = scoring.progress(user_id)
    return Standing(
        rank=None,
        user_id=user_id,
        nickname=store.users[user_id].nickname,
        improvement_pct=p.improvement_pct,
        est_savings_usd=p.est_savings_usd,
        trips_counted=p.trips_counted,
    )


@router.get("/leaderboard", response_model=Leaderboard)
async def get_leaderboard(period: Period = Period.week, user: store.UserRecord = Depends(get_current_user)) -> Leaderboard:
    crew = next((c for c in store.crews.values() if user.user_id in c.members), None)
    if crew is None:
        raise ApiError(404, "not_in_crew", "Create or join a crew to see its leaderboard")

    members = [_standing(uid) for uid in crew.members]
    ranked = sorted(
        (m for m in members if m.improvement_pct is not None),
        key=lambda m: (m.improvement_pct, m.est_savings_usd),
        reverse=True,
    )
    unranked = sorted((m for m in members if m.improvement_pct is None), key=lambda m: (-m.trips_counted, m.nickname))

    return Leaderboard(
        crew_id=crew.crew_id,
        crew_name=crew.name,
        member_count=len(crew.members),
        active=len(crew.members) >= MIN_ACTIVE_MEMBERS,
        period=period,
        generated_at=datetime.now(timezone.utc),
        standings=[m.model_copy(update={"rank": i}) for i, m in enumerate(ranked, start=1)] + unranked,
        is_demo=crew.is_demo,
    )
