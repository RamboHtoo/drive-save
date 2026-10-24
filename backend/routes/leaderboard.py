"""Drivers compete against each other inside their crew; the leaderboard ranks the caller's crew."""

from fastapi import APIRouter, Depends

import repo
from auth import get_current_user
from models.leaderboard import Leaderboard, Period

router = APIRouter(tags=["leaderboard"])


@router.get("/leaderboard", response_model=Leaderboard)
async def get_leaderboard(period: Period = Period.week, user: repo.User = Depends(get_current_user)) -> Leaderboard:
    return await repo.leaderboard(user.user_id, period)
