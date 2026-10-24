from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, status

import store
from auth import get_current_user, hash_token, new_token
from errors import ApiError
from models.users import Progress, UserCreate, UserCreated
from models.vehicles import VehicleData
from services import scoring

router = APIRouter(tags=["users"])


@router.post("/users", response_model=UserCreated, status_code=status.HTTP_201_CREATED)
async def create_user(body: UserCreate) -> UserCreated:
    token = new_token()
    user = store.UserRecord(user_id=uuid4(), nickname=body.nickname, token_hash=hash_token(token))
    store.users[user.user_id] = user
    store.users_by_token_hash[user.token_hash] = user
    return UserCreated(user_id=user.user_id, nickname=user.nickname, token=token)


@router.put("/users/me/vehicle", response_model=VehicleData)
async def set_vehicle(body: VehicleData, user: store.UserRecord = Depends(get_current_user)) -> VehicleData:
    """Stores the car's data as sent; trips uploaded from now on carry it to the cost model."""
    user.vehicle = body.root
    return body


@router.get("/users/me/vehicle", response_model=VehicleData)
async def get_vehicle(user: store.UserRecord = Depends(get_current_user)) -> VehicleData:
    if user.vehicle is None:
        raise ApiError(404, "vehicle_not_set", "Send the car first with PUT /users/me/vehicle")
    return VehicleData(user.vehicle)


@router.get("/users/{user_id}/progress", response_model=Progress)
async def get_progress(user_id: UUID, user: store.UserRecord = Depends(get_current_user)) -> Progress:
    if user_id != user.user_id:
        raise ApiError(403, "forbidden", "You can only view your own progress")
    return scoring.progress(user_id)
