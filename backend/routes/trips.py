from datetime import datetime, timezone
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, Response, status

import store
from auth import get_current_user
from errors import ApiError
from models.trips import Receipt, TripCreate, TripCreated
from services import cost_model

router = APIRouter(tags=["trips"])


@router.post("/trips", response_model=TripCreated, status_code=status.HTTP_201_CREATED)
async def upload_trip(body: TripCreate, response: Response, user: store.UserRecord = Depends(get_current_user)) -> TripCreated:
    key = (user.user_id, body.client_trip_id)
    existing = store.trip_ids_by_client_id.get(key)
    if existing:
        # Same upload retried from the phone's offline queue: return the original trip.
        response.status_code = status.HTTP_200_OK
        return TripCreated(trip_id=existing, receipt_url=f"/trips/{existing}/receipt", duplicate=True)

    record = store.TripRecord(trip_id=uuid4(), user_id=user.user_id, trip=body, uploaded_at=datetime.now(timezone.utc))
    store.trips[record.trip_id] = record
    store.trip_ids_by_client_id[key] = record.trip_id
    return TripCreated(trip_id=record.trip_id, receipt_url=f"/trips/{record.trip_id}/receipt", duplicate=False)


@router.get("/trips/{trip_id}/receipt", response_model=Receipt)
async def get_receipt(trip_id: UUID, user: store.UserRecord = Depends(get_current_user)) -> Receipt:
    record = store.trips.get(trip_id)
    if record is None:
        raise ApiError(404, "trip_not_found", "No trip with that id")
    if record.user_id != user.user_id:
        raise ApiError(403, "forbidden", "You can only view your own receipts")
    return cost_model.price_trip(record)
