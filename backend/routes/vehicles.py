"""The vehicle list the app's car picker walks: brand, then model, then model year.

No auth: the app shows the picker before sign-up. Make and model are query parameters
because model names can contain slashes ("ACCORD EX/EX-L COUPE"). Matching ignores
case and extra spaces.
"""

from fastapi import APIRouter, Query

import repo
from errors import ApiError
from models.vehicles import Vehicle, VehicleMakes, VehicleModels, VehicleYears

router = APIRouter(prefix="/vehicles", tags=["vehicles"])

_Make = Query(min_length=1, max_length=100, description="A brand from GET /vehicles/makes")
_Model = Query(min_length=1, max_length=200, description="A model from GET /vehicles/models")


@router.get("/makes", response_model=VehicleMakes)
async def list_makes() -> VehicleMakes:
    return VehicleMakes(makes=await repo.vehicle_makes())


@router.get("/models", response_model=VehicleModels)
async def list_models(make: str = _Make) -> VehicleModels:
    found = await repo.vehicle_models(make)
    if found is None:
        raise ApiError(404, "vehicle_not_found", f"No brand {make!r} in the vehicle list")
    return VehicleModels(make=found[0], models=found[1])


@router.get("/years", response_model=VehicleYears)
async def list_years(make: str = _Make, model: str = _Model) -> VehicleYears:
    found = await repo.vehicle_years(make, model)
    if found is None:
        raise ApiError(404, "vehicle_not_found", f"No model {model!r} of {make!r} in the vehicle list")
    return VehicleYears(make=found[0], model=found[1], years=found[2])


@router.get("/details", response_model=Vehicle)
async def get_vehicle(make: str = _Make, model: str = _Model, year: int = Query(ge=1900, le=2100)) -> Vehicle:
    """The car's specs, MPG and fuel model parameters: what sign-up stores for the driver."""
    found = await repo.vehicle(make, model, year)
    if found is None:
        raise ApiError(404, "vehicle_not_found", f"No {year} {make} {model} in the vehicle list")
    return found
