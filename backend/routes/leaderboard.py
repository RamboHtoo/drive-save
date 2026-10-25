"""Drivers compete against each other inside their crew; the leaderboard ranks the caller's crew."""

from fastapi import APIRouter, Depends

import repo
from services.league_demo import legacy_board
from auth import get_current_user
from models.leaderboard import Leaderboard, Period

router = APIRouter(tags=["leaderboard"])


@router.get("/leaderboard", response_model=Leaderboard, deprecated=True)
async def get_leaderboard(period: Period = Period.week, user: repo.User = Depends(get_current_user)) -> Leaderboard:
    return await legacy_board(user, period)
