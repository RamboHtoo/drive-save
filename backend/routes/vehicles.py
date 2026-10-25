"""The vehicle list the app's car picker walks: brand, then model, then model year.

No auth: the app shows the picker before sign-up. Make and model are query parameters
because model names can contain slashes ("ACCORD EX/EX-L COUPE"). Matching ignores
case and extra spaces.

A "+" in a query string is ambiguous: form encoding (JavaScript's URLSearchParams,
Python's requests) sends spaces as "+" and a plus sign as "%2B", but iOS's
URLComponents sends a plus sign unencoded, with spaces as "%20". 54 model names
contain a plus ("RX 450h+ AWD"), and reading it as a space can even land on another
car ("RX 450h AWD"). So names are looked up both ways: first the way the client's
spaces suggest, then the other.
"""

from collections.abc import Awaitable, Callable
from itertools import product
from typing import Annotated
from urllib.parse import unquote, unquote_plus

from fastapi import APIRouter, Query, Request

import repo
from errors import ApiError
from models.common import Text
from models.vehicles import Vehicle, VehicleMakes, VehicleModels, VehicleYears

router = APIRouter(prefix="/vehicles", tags=["vehicles"])

_Make = Annotated[Text, Query(min_length=1, max_length=100, description="A brand from GET /vehicles/makes; encode a plus sign as %2B")]
_Model = Annotated[Text, Query(min_length=1, max_length=200, description="A model from GET /vehicles/models; encode a plus sign as %2B")]


def _readings(request: Request, name: str, decoded: str) -> list[str]:
    """What the client may have meant by query parameter `name`, likeliest first."""
    for part in request.scope["query_string"].decode("latin-1").split("&"):
        key, _, raw = part.partition("=")
        if unquote_plus(key) == name and "+" in raw:
            as_space, as_plus = unquote_plus(raw), unquote(raw)
            return [as_plus, as_space] if "%20" in raw else [as_space, as_plus]
    return [decoded]


async def _first_found(lookup: Callable[..., Awaitable], *readings: list[str]):
    for names in product(*readings):
        found = await lookup(*names)
        if found is not None:
            return found
    return None


@router.get("/makes", response_model=VehicleMakes)
async def list_makes() -> VehicleMakes:
    return VehicleMakes(makes=await repo.vehicle_makes())


@router.get("/models", response_model=VehicleModels)
async def list_models(request: Request, make: _Make) -> VehicleModels:
    found = await _first_found(repo.vehicle_models, _readings(request, "make", make))
    if found is None:
        raise ApiError(404, "vehicle_not_found", f"No brand {make!r} in the vehicle list")
    return VehicleModels(make=found[0], models=found[1])


@router.get("/years", response_model=VehicleYears)
async def list_years(request: Request, make: _Make, model: _Model) -> VehicleYears:
    found = await _first_found(repo.vehicle_years, _readings(request, "make", make), _readings(request, "model", model))
    if found is None:
        raise ApiError(404, "vehicle_not_found", f"No model {model!r} of {make!r} in the vehicle list")
    return VehicleYears(make=found[0], model=found[1], years=found[2])


@router.get("/details", response_model=Vehicle)
async def get_vehicle(request: Request, make: _Make, model: _Model, year: int = Query(ge=1900, le=2100)) -> Vehicle:
    """The car's specs, MPG and fuel model parameters: what sign-up stores for the driver."""
    found = await _first_found(
        lambda make_name, model_name: repo.vehicle(make_name, model_name, year), _readings(request, "make", make), _readings(request, "model", model)
    )
    if found is None:
        raise ApiError(404, "vehicle_not_found", f"No {year} {make} {model} in the vehicle list")
    return found
