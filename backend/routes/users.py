from uuid import UUID

from fastapi import APIRouter, Depends, status

import repo
from auth import get_current_user, hash_token, new_token
from errors import ApiError
from models.users import Progress, UserCreate, UserCreated
from models.vehicles import VehicleData

router = APIRouter(tags=["users"])


@router.post("/users", response_model=UserCreated, status_code=status.HTTP_201_CREATED)
async def create_user(body: UserCreate) -> UserCreated:
    vehicle = None
    if body.vehicle is not None:
        choice = body.vehicle
        vehicle = await repo.vehicle(choice.make, choice.model, choice.year)
        if vehicle is None:
            raise ApiError(422, "vehicle_not_found", f"No {choice.year} {choice.make} {choice.model} in the vehicle list; pick one from GET /vehicles/years")
    token = new_token()
    user_id = await repo.create_user(body.nickname, hash_token(token), vehicle)
    return UserCreated(user_id=user_id, nickname=body.nickname, token=token, vehicle=vehicle)


@router.put("/users/me/vehicle", response_model=VehicleData)
async def set_vehicle(body: VehicleData, user: repo.User = Depends(get_current_user)) -> VehicleData:
    """Stores the car's data as sent; trips uploaded from now on carry it to the cost model."""
    await repo.set_vehicle(user.user_id, body.root)
    return body


@router.get("/users/me/vehicle", response_model=VehicleData)
async def get_vehicle(user: repo.User = Depends(get_current_user)) -> VehicleData:
    if user.vehicle is None:
        raise ApiError(404, "vehicle_not_set", "Send the car first with PUT /users/me/vehicle")
    return VehicleData(user.vehicle)


@router.get("/users/{user_id}/progress", response_model=Progress)
async def get_progress(user_id: UUID, user: repo.User = Depends(get_current_user)) -> Progress:
    if user_id != user.user_id:
        raise ApiError(403, "forbidden", "You can only view your own progress")
    return await repo.progress(user_id)
