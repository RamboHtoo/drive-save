from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, status

import store
from auth import get_current_user, hash_token, new_token
from errors import ApiError
from models.users import Progress, UserCreate, UserCreated, VehicleIn, VehicleOut
from services import scoring

router = APIRouter(tags=["users"])


@router.post("/users", response_model=UserCreated, status_code=status.HTTP_201_CREATED)
async def create_user(body: UserCreate) -> UserCreated:
    token = new_token()
    user = store.UserRecord(user_id=uuid4(), nickname=body.nickname, token_hash=hash_token(token))
    store.users[user.user_id] = user
    store.users_by_token_hash[user.token_hash] = user
    return UserCreated(user_id=user.user_id, nickname=user.nickname, token=token)


@router.put("/users/me/vehicle", response_model=VehicleOut)
async def set_vehicle(body: VehicleIn, user: store.UserRecord = Depends(get_current_user)) -> VehicleOut:
    if body.mpg_city and body.mpg_hwy:
        vehicle = VehicleOut(**body.model_dump(), mpg_source="manual")
    else:
        # TODO(stage 2): look up MPG on fueleconomy.gov (/ws/rest/vehicle/menu/... -> city08, highway08).
        vehicle = VehicleOut(
            year=body.year,
            make=body.make,
            model=body.model,
            mpg_city=scoring.DEFAULT_MPG_CITY,
            mpg_hwy=scoring.DEFAULT_MPG_HWY,
            mpg_source="mock",
        )
    user.vehicle = vehicle
    return vehicle


@router.get("/users/{user_id}/progress", response_model=Progress)
async def get_progress(user_id: UUID, user: store.UserRecord = Depends(get_current_user)) -> Progress:
    if user_id != user.user_id:
        raise ApiError(403, "forbidden", "You can only view your own progress")
    return scoring.progress(user_id)
