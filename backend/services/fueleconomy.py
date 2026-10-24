"""Client for the fueleconomy.gov web services: year -> make -> model -> option -> vehicle.

Responses are cached in memory for the life of the process; the data rarely changes.
Docs: https://www.fueleconomy.gov/feg/ws/index.shtml
"""

import asyncio
import json
import urllib.parse
import urllib.request
from urllib.error import HTTPError, URLError

from errors import ApiError
from models.vehicles import VehicleOption, VehicleSpecs

BASE_URL = "https://www.fueleconomy.gov/ws/rest/vehicle"
TIMEOUT_S = 8

_cache: dict[str, object] = {}


def _fetch(url: str) -> object:
    request = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "drive-save-backend"})
    with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:
        return json.loads(response.read() or b"null")


async def _get(path: str, **params: object) -> object:
    url = f"{BASE_URL}/{path}" + (f"?{urllib.parse.urlencode(params)}" if params else "")
    if url not in _cache:
        try:
            _cache[url] = await asyncio.to_thread(_fetch, url)
        except HTTPError as exc:
            if exc.code == 404:
                return None  # unknown vehicle id
            raise ApiError(502, "vehicle_data_unavailable", f"fueleconomy.gov returned HTTP {exc.code}") from exc
        except (URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise ApiError(502, "vehicle_data_unavailable", "Could not reach fueleconomy.gov") from exc
    return _cache[url]


def _menu(data: object) -> list[dict]:
    # An unknown make or model comes back as null, and a single item as a bare object instead of a list.
    items = data.get("menuItem") if isinstance(data, dict) else None
    if items is None:
        return []
    return [items] if isinstance(items, dict) else items


def _number(value: object) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number or None  # fueleconomy.gov uses 0 for "not applicable"


async def years() -> list[int]:
    return [int(item["value"]) for item in _menu(await _get("menu/year"))]


async def makes(year: int) -> list[str]:
    return [item["value"] for item in _menu(await _get("menu/make", year=year))]


async def models(year: int, make: str) -> list[str]:
    return [item["value"] for item in _menu(await _get("menu/model", year=year, make=make))]


async def options(year: int, make: str, model: str) -> list[VehicleOption]:
    items = _menu(await _get("menu/options", year=year, make=make, model=model))
    return [VehicleOption(vehicle_id=int(item["value"]), description=item["text"]) for item in items]


async def vehicle(vehicle_id: int) -> VehicleSpecs:
    record = await _get(str(vehicle_id))
    if not isinstance(record, dict) or "id" not in record:
        raise ApiError(404, "vehicle_not_found", "No vehicle with that id on fueleconomy.gov")
    fuel_type = record.get("fuelType1") or None
    cylinders = _number(record.get("cylinders"))
    return VehicleSpecs(
        vehicle_id=int(record["id"]),
        year=int(record["year"]),
        make=record["make"],
        model=record["model"],
        vehicle_class=record.get("VClass") or None,
        fuel_type=fuel_type,
        powertrain=record.get("atvType") or None,
        transmission=record.get("trany") or None,
        drive=record.get("drive") or None,
        cylinders=int(cylinders) if cylinders else None,
        engine_displacement_l=_number(record.get("displ")),
        mpg_city=float(record["city08"]),
        mpg_hwy=float(record["highway08"]),
        mpg_combined=float(record["comb08"]),
        kwh_per_100mi=_number(record.get("combE")) if fuel_type == "Electricity" else None,
        epa_annual_fuel_cost_usd=_number(record.get("fuelCost08")),
        source_url=f"{BASE_URL}/{record['id']}",
    )
