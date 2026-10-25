"""The driver's car.

The app picks it from the EPA vehicle list (GET /vehicles/...): brand, then model,
then model year. Sign-up takes that choice and stores the chosen car; see
docs/vehicle-catalog.md for where each car's fuel model parameters come from.

PUT /users/me/vehicle still takes a car as any JSON object: the backend stores it
and hands it back unchanged.
"""

import json
from uuid import UUID

from pydantic import BaseModel, Field, JsonValue, RootModel, model_validator

from models.common import Text, storable_text

MAX_FIELDS = 200
MAX_BYTES = 20_000


def _check_strings(value: JsonValue) -> None:
    """Every key and string in the JSON must be text Postgres can store in jsonb."""
    if isinstance(value, str):
        storable_text(value)
    elif isinstance(value, list):
        for item in value:
            _check_strings(item)
    elif isinstance(value, dict):
        for key, item in value.items():
            storable_text(key)
            _check_strings(item)


class VehicleData(RootModel[dict[str, JsonValue]]):
    @model_validator(mode="after")
    def check_size(self) -> "VehicleData":
        if not self.root:
            raise ValueError("vehicle data needs at least one field")
        if len(self.root) > MAX_FIELDS:
            raise ValueError(f"vehicle data can have at most {MAX_FIELDS} fields")
        try:
            encoded = json.dumps(self.root, allow_nan=False)
        except ValueError:
            raise ValueError("vehicle data can't contain NaN or infinity") from None
        if len(encoded) > MAX_BYTES:
            raise ValueError(f"vehicle data must be under {MAX_BYTES} bytes")
        _check_strings(self.root)
        return self


class VehicleMakes(BaseModel):
    makes: list[str] = Field(description="Every brand in the vehicle list, alphabetical")


class VehicleModels(BaseModel):
    make: str
    models: list[str] = Field(description="Every model of the brand in any model year, alphabetical")


class VehicleYears(BaseModel):
    make: str
    model: str
    years: list[int] = Field(description="Model years of this model in the list, newest first")


class VehicleChoice(BaseModel):
    """A car from the vehicle list. Matching ignores case and extra spaces."""

    make: Text = Field(min_length=1, max_length=100)
    model: Text = Field(min_length=1, max_length=200)
    year: int = Field(ge=1900, le=2100)


class VehicleSpecs(BaseModel):
    fuel_type: str = Field(description="gasoline, diesel, e85, electricity, hydrogen, cng, lpg or other")
    vehicle_type: str | None = Field(description="EPA's Car, Truck or Both")
    engine_displacement_l: float | None
    cylinders: int | None
    rated_horsepower: float | None
    transmission: str | None
    gears: int | None
    drive: str | None
    test_weight_lb: float | None = Field(description="EPA equivalent test weight: the car plus a standard load")


class MpgEstimate(BaseModel):
    city: float | None
    highway: float | None
    combined: float | None
    is_estimate: bool = Field(True, description="Estimated from the EPA lab results; can differ from the window sticker by about 1 MPG")


class VehicleParameter(BaseModel):
    key: str = Field(description="The fuel model's name for it, as in a receipt's assumptions")
    value: float
    unit: str
    method: str = Field(description="How it was worked out for this car")
    is_estimate: bool = True


class VehicleSource(BaseModel):
    dataset: str = "EPA Test Car List"
    test_vehicle_id: str | None
    test_configuration: int | None
    configurations_tested: int = Field(description="Configurations EPA tested for this model year; the specs and parameters are the typical one's")


class Vehicle(BaseModel):
    vehicle_id: UUID = Field(description="Stable for this make, model and year")
    make: str
    model: str
    year: int
    supported: bool = Field(description="False when the fuel model can't describe this car, e.g. an electric car; then parameters is empty")
    specs: VehicleSpecs
    mpg: MpgEstimate
    parameters: list[VehicleParameter] = Field(description="The fuel model's per-car parameters, worked out from this car's EPA tests")
    flags: list[str] = Field(description="Caveats, e.g. drives_with_engine_off for hybrids")
    source: VehicleSource
