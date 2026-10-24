from uuid import UUID

from fastapi import APIRouter, Depends, Response, status

import repo
from auth import get_current_user
from models.cost_model import CostModelInput
from models.trips import Receipt, TripCreate, TripCreated

router = APIRouter(tags=["trips"])


@router.post("/trips", response_model=TripCreated, status_code=status.HTTP_201_CREATED)
async def upload_trip(body: TripCreate, response: Response, user: repo.User = Depends(get_current_user)) -> TripCreated:
    trip_id, duplicate = await repo.accept_trip(user, body)
    if duplicate:
        # Same upload retried from the phone's offline queue: return the original trip.
        response.status_code = status.HTTP_200_OK
    return TripCreated(trip_id=trip_id, receipt_url=f"/trips/{trip_id}/receipt", duplicate=duplicate)


@router.get("/trips/{trip_id}/receipt", response_model=Receipt)
async def get_receipt(trip_id: UUID, user: repo.User = Depends(get_current_user)) -> Receipt:
    return await repo.receipt(trip_id, user.user_id)


@router.get("/trips/{trip_id}/cost-input", response_model=CostModelInput)
async def get_cost_input(trip_id: UUID, user: repo.User = Depends(get_current_user)) -> CostModelInput:
    """Exactly what the cost model receives for this trip. For building and debugging the model."""
    return await repo.cost_input(trip_id, user.user_id)
