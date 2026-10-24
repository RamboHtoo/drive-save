from pydantic import BaseModel, Field


class VehicleOption(BaseModel):
    vehicle_id: int
    description: str = Field(description='Transmission and engine, e.g. "Auto (AV-S7), 4 cyl, 1.5 L, Turbo"')


class VehicleSelect(BaseModel):
    vehicle_id: int = Field(gt=0, description="From GET /vehicles/options")


class VehicleSpecs(BaseModel):
    """One exact car (model year, make, model, engine and transmission), from fueleconomy.gov."""

    vehicle_id: int
    year: int
    make: str
    model: str
    vehicle_class: str | None = Field(description='EPA size class, e.g. "Midsize Cars"')
    fuel_type: str | None = Field(description='e.g. "Regular Gasoline", "Premium Gasoline", "Diesel", "Electricity"')
    powertrain: str | None = Field(description='EPA alternative-fuel type such as "Hybrid", "Plug-in Hybrid", "EV" or "FCV"; None for a regular gas car')
    transmission: str | None
    drive: str | None
    cylinders: int | None
    engine_displacement_l: float | None
    mpg_city: float = Field(description="EPA city MPG (MPGe for electric and hydrogen cars)")
    mpg_hwy: float
    mpg_combined: float
    kwh_per_100mi: float | None = Field(description="Electricity use; electric cars only")
    epa_annual_fuel_cost_usd: float | None = Field(description="EPA's estimated annual fuel cost for this car")
    weight_lb: float | None = Field(default=None, description="Not provided by fueleconomy.gov; None until a weight source is added")
    weight_source: str | None = None
    source_url: str
