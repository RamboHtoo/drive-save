from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends

import store
from auth import get_current_user
from errors import ApiError
from models.crews import MIN_ACTIVE_MEMBERS
from models.leaderboard import Leaderboard, Period, Scope, Standing
from services import scoring
from services.demo import DEMO_CREWS

router = APIRouter(tags=["leaderboard"])


def _ranked(standings: list[Standing]) -> list[Standing]:
    ordered = sorted(standings, key=lambda s: (s.improvement_pct, s.est_savings_usd), reverse=True)
    return [s.model_copy(update={"rank": i}) for i, s in enumerate(ordered, start=1)]


def _member_standing(user_id: UUID) -> Standing:
    p = scoring.progress(user_id)
    return Standing(
        rank=0,
        id=user_id,
        name=store.users[user_id].nickname,
        improvement_pct=p.improvement_pct or 0.0,
        est_savings_usd=p.est_savings_usd,
    )


@router.get("/leaderboard", response_model=Leaderboard)
async def get_leaderboard(
    scope: Scope = Scope.crews,
    period: Period = Period.week,
    crew_id: UUID | None = None,
    user: store.UserRecord = Depends(get_current_user),
) -> Leaderboard:
    if scope is Scope.members:
        if crew_id is None:
            raise ApiError(400, "crew_id_required", "scope=members needs a crew_id")
        crew = store.crews.get(crew_id)
        if crew is None:
            raise ApiError(404, "crew_not_found", "No crew with that id")
        if user.user_id not in crew.members:
            raise ApiError(403, "forbidden", "Only crew members can see member standings")
        standings = [_member_standing(uid) for uid in crew.members]
    else:
        standings = list(DEMO_CREWS)
        for crew in store.crews.values():
            if len(crew.members) < MIN_ACTIVE_MEMBERS:
                continue  # crews under 4 members are not ranked
            members = [_member_standing(uid) for uid in crew.members]
            standings.append(
                Standing(
                    rank=0,
                    id=crew.crew_id,
                    name=crew.name,
                    members=len(members),
                    improvement_pct=round(sum(m.improvement_pct for m in members) / len(members), 1),
                    est_savings_usd=round(sum(m.est_savings_usd for m in members), 2),
                    is_demo=crew.is_demo,
                )
            )

    return Leaderboard(
        scope=scope,
        period=period,
        crew_id=crew_id,
        generated_at=datetime.now(timezone.utc),
        standings=_ranked(standings),
    )
