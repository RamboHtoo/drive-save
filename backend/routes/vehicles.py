"""Car picker: model year -> make -> model -> option (engine and transmission) -> specs."""

from typing import Annotated

from fastapi import APIRouter, Depends, Query

import store
from auth import get_current_user
from models.vehicles import VehicleOption, VehicleSpecs
from services import fueleconomy

router = APIRouter(prefix="/vehicles", tags=["vehicles"])

Year = Annotated[int, Query(ge=1984, le=2100)]
Name = Annotated[str, Query(min_length=1, max_length=80)]
Driver = Annotated[store.UserRecord, Depends(get_current_user)]


@router.get("/years", response_model=list[int])
async def list_years(_: Driver) -> list[int]:
    return await fueleconomy.years()


@router.get("/makes", response_model=list[str])
async def list_makes(year: Year, _: Driver) -> list[str]:
    return await fueleconomy.makes(year)


@router.get("/models", response_model=list[str])
async def list_models(year: Year, make: Name, _: Driver) -> list[str]:
    return await fueleconomy.models(year, make)


@router.get("/options", response_model=list[VehicleOption])
async def list_options(year: Year, make: Name, model: Name, _: Driver) -> list[VehicleOption]:
    return await fueleconomy.options(year, make, model)


@router.get("/{vehicle_id}", response_model=VehicleSpecs)
async def get_vehicle(vehicle_id: int, _: Driver) -> VehicleSpecs:
    return await fueleconomy.vehicle(vehicle_id)
