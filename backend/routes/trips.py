from datetime import datetime, timezone
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, Response, status

import store
from auth import get_current_user
from errors import ApiError
from models.cost_model import CostModelInput
from models.trips import Receipt, TripCreate, TripCreated
from services import cost_model

router = APIRouter(tags=["trips"])


@router.post("/trips", response_model=TripCreated, status_code=status.HTTP_201_CREATED)
async def upload_trip(body: TripCreate, response: Response, user: store.UserRecord = Depends(get_current_user)) -> TripCreated:
    key = (user.user_id, body.client_trip_id)
    existing = store.trip_ids_by_client_id.get(key)
    if existing:
        # Validation normalizes the payload, so an identical retry compares equal.
        if store.trips[existing].trip != body:
            raise ApiError(409, "trip_conflict", "A different trip was already uploaded with this client_trip_id")
        # Same upload retried from the phone's offline queue: return the original trip.
        response.status_code = status.HTTP_200_OK
        return TripCreated(trip_id=existing, receipt_url=f"/trips/{existing}/receipt", duplicate=True)

    record = store.TripRecord(
        trip_id=uuid4(),
        user_id=user.user_id,
        trip=body,
        uploaded_at=datetime.now(timezone.utc),
        vehicle=user.vehicle,
    )
    store.trips[record.trip_id] = record
    store.trip_ids_by_client_id[key] = record.trip_id
    return TripCreated(trip_id=record.trip_id, receipt_url=f"/trips/{record.trip_id}/receipt", duplicate=False)


def _own_trip(trip_id: UUID, user: store.UserRecord) -> store.TripRecord:
    record = store.trips.get(trip_id)
    if record is None:
        raise ApiError(404, "trip_not_found", "No trip with that id")
    if record.user_id != user.user_id:
        raise ApiError(403, "forbidden", "You can only view your own trips")
    return record


@router.get("/trips/{trip_id}/receipt", response_model=Receipt)
async def get_receipt(trip_id: UUID, user: store.UserRecord = Depends(get_current_user)) -> Receipt:
    return cost_model.price_trip(_own_trip(trip_id, user))


@router.get("/trips/{trip_id}/cost-input", response_model=CostModelInput)
async def get_cost_input(trip_id: UUID, user: store.UserRecord = Depends(get_current_user)) -> CostModelInput:
    """Exactly what the cost model receives for this trip. For building and debugging the model."""
    return cost_model.build_input(_own_trip(trip_id, user))
