"""Current cost ranking and explicitly gated synthetic showcase routes."""
from uuid import UUID
from fastapi import APIRouter, Depends
from auth import get_current_user
from services import league_demo

router = APIRouter(tags=["league costs"])

@router.get('/leaderboard/costs')
async def costs(user=Depends(get_current_user)):
    return await league_demo.board_for(user)

@router.get('/leaderboard/demo')
async def showcase(user=Depends(get_current_user)):
    return await league_demo.board_for(user, True)

@router.get('/developer/league-demo/plan')
async def plan(user=Depends(get_current_user)):
    return await league_demo.plan_for(user)

@router.post('/developer/league-demo/seed/{expected_league}')
async def seed(expected_league: UUID, user=Depends(get_current_user)):
    return await league_demo.seed(user, expected_league)

@router.delete('/developer/league-demo/{batch}')
async def cleanup(batch: UUID, user=Depends(get_current_user)):
    return await league_demo.cleanup(user, batch)
