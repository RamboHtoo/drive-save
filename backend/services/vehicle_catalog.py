"""The car picker: one entry per brand, model and model year, built from EPA test rows.

A model year usually has several tested configurations (engine, transmission, drive
layout), each with its own test vehicle. Every configuration gets its own fuel model
parameters (vehicle_params). The entry the app shows is the typical one: among the
configurations the model supports, gasoline before diesel and automatic before
manual, the one with the median lab fuel use. All of them are kept in the entry's
`variants`.

Left out of the picker but kept in epa_test_cars: rows whose brand is unknown or not
a car anyone owns (epa_dataset.normalize_vehicle), and police and emergency vehicles.
"""

from collections import Counter, defaultdict
from uuid import NAMESPACE_URL, UUID, uuid5

from services import vehicle_params
from services.epa_dataset import model_key

CATALOG_VERSION = "1"  # change it when entries or parameters are computed differently, so the loader reloads
FTP_PROCEDURES = {2, 21, 25, 31, 35}  # FTP exhaust tests on Federal or California fuel; not cold CO (11) or 50 F (52)
FUELS = ("gasoline", "diesel", "e85", "electricity", "hydrogen", "cng", "lpg", "other")  # which tests describe a configuration, best first
_SPECS = (
    "vehicle_type", "displacement_l", "cylinders", "rated_hp", "transmission", "transmission_code", "gears", "drive",
    "drive_code", "etw_lb", "axle_ratio", "nv_ratio", "target_a_lbf", "target_b_lbf_per_mph", "target_c_lbf_per_mph2",
)


def vehicle_id(make: str, model: str, year: int) -> UUID:
    """Stable across reloads, so stored choices keep pointing at the same entry."""
    return uuid5(NAMESPACE_URL, f"drive-save:vehicle:{model_key(make)}|{model_key(model)}|{year}")


def fuel_family(description: str | None) -> str:
    """The kind of fuel an EPA test used; "cold" for the cold-temperature CO tests, which the parameters skip."""
    text = (description or "").lower()
    if "cold co" in text:
        return "cold"
    for word, family in (("diesel", "diesel"), ("e85", "e85"), ("electric", "electricity"), ("hydrogen", "hydrogen"), ("cng", "cng"), ("lpg", "lpg")):
        if word in text:
            return family
    return "gasoline" if "gasoline" in text or "indolene" in text else "other"


def build(rows: list[dict]) -> list[dict]:
    names = _display_names(rows)
    groups: dict[tuple, dict[tuple, list[dict]]] = defaultdict(lambda: defaultdict(list))
    for row in rows:
        if row["make"] is None or row["model_year"] is None or row["police_emergency"] == "Y":
            continue
        key = (model_key(row["make"]), model_key(row["model"]), row["model_year"])
        groups[key][(row["test_vehicle_id"] or "", row["configuration"])].append(row)
    return [_entry(key, configurations, names) for key, configurations in sorted(groups.items())]


def _display_names(rows: list[dict]) -> dict[tuple, str]:
    """Each brand's and model's most common spelling; on a tie, the newest model year's."""
    counts: dict[tuple, Counter] = defaultdict(Counter)
    newest: dict[tuple, int] = {}
    for row in rows:
        if row["make"] is None:
            continue
        make = model_key(row["make"])
        for key, name in (((make,), row["make"]), ((make, model_key(row["model"])), row["model"])):
            counts[key][name] += 1
            newest[key, name] = max(newest.get((key, name), 0), row["model_year"] or 0)
    return {key: max(spellings, key=lambda name: (spellings[name], newest[key, name], name)) for key, spellings in counts.items()}


def _entry(key: tuple, configurations: dict[tuple, list[dict]], names: dict[tuple, str]) -> dict:
    make_key, model_key_, year = key
    make, model = names[(make_key,)], names[(make_key, model_key_)]
    variants = sorted((_configuration(rows) for rows in configurations.values()), key=lambda v: (v["test_vehicle_id"] or "", v["configuration"] if v["configuration"] is not None else -1))
    typical = _typical(variants)
    specs, params = typical["specs"], typical["params"]
    values = params.values or {}
    label = params.label_mpg or {}
    road_original = {"a_lbf": specs["target_a_lbf"], "b_lbf_per_mph": specs["target_b_lbf_per_mph"], "c_lbf_per_mph2": specs["target_c_lbf_per_mph2"]}
    profile = None
    if params.supported:  # the car in the shape of the fuel model's vehicle_profile (drive_save_model.reference_profile)
        profile = {
            "id": f"epa-{year}-{typical['test_vehicle_id']}-config{typical['configuration']}",
            "name": f"{year} {make} {model}",
            "year": year,
            "make": make,
            "model": model,
            "transmission": specs["transmission"],
            "fuel": typical["fuel_description"],
            "test_vehicle_id": typical["test_vehicle_id"],
            "test_configuration": typical["configuration"],
            "mass_kg": params.mass_kg,
            "mass_basis": "EPA equivalent test weight; actual passenger/cargo mass unknown",
            "rated_horsepower": specs["rated_hp"],
            "road_load_original": road_original,
            "road_load_si": params.road_load_si,
            "city_mpg": label.get("city"),
            "highway_mpg": label.get("highway"),
            "combined_mpg": label.get("combined"),
            "mpg_basis": "EPA derived 5-cycle estimate from this test vehicle's lab results",
        }
    return {
        "id": vehicle_id(make, model, year),
        "make": make,
        "model": model,
        "model_year": year,
        "make_key": make_key,
        "model_key": model_key_,
        "supported": params.supported,
        "fuel_type": typical["fuel"],
        "vehicle_type": specs["vehicle_type"],
        "test_vehicle_id": typical["test_vehicle_id"],
        "test_configuration": typical["configuration"],
        "variant_count": len(variants),
        "displacement_l": specs["displacement_l"],
        "cylinders": specs["cylinders"],
        "rated_hp": specs["rated_hp"],
        "transmission": specs["transmission"],
        "gears": specs["gears"],
        "drive": specs["drive"],
        "etw_lb": specs["etw_lb"],
        "mass_kg": specs["etw_lb"] * vehicle_params.LB_TO_KG if specs["etw_lb"] else None,
        "nv_ratio": specs["nv_ratio"],
        "axle_ratio": specs["axle_ratio"],
        "target_a_lbf": road_original["a_lbf"],
        "target_b_lbf_per_mph": road_original["b_lbf_per_mph"],
        "target_c_lbf_per_mph2": road_original["c_lbf_per_mph2"],
        "lab_ftp_mpg": params.lab_mpg["ftp"],
        "lab_hot_udds_mpg": params.lab_mpg["hot_udds"],
        "lab_hwy_mpg": params.lab_mpg["highway"],
        "lab_us06_mpg": params.lab_mpg["us06"],
        "label_city_mpg": label.get("city"),
        "label_highway_mpg": label.get("highway"),
        "label_combined_mpg": label.get("combined"),
        "marginal_wheel_efficiency": values.get("marginal_wheel_efficiency"),
        "idle_rate_gal_per_hour": values.get("idle_rate"),
        "coast_deceleration_g": values.get("coast_deceleration"),
        "enrichment_start_fraction": values.get("enrichment_start_fraction"),
        "enrichment_max": values.get("enrichment_max"),
        "drivetrain_factor": values.get("drivetrain_factor"),
        "fuel_energy_j_per_gal": values.get("fuel_energy"),
        "parameters": params.parameters,
        "flags": params.flags,
        "fit_error": params.fit_error,
        "vehicle_profile": profile,
        "variants": [_variant_summary(v, v is typical) for v in variants],
        "catalog_version": CATALOG_VERSION,
    }


def _configuration(rows: list[dict]) -> dict:
    """One tested configuration: its specs, the tests that describe it, and its parameters."""
    families = Counter(fuel_family(row["fuel"]) for row in rows)
    fuel = next((family for family in FUELS if families[family]), "other")
    tests = [row for row in rows if fuel_family(row["fuel"]) == fuel]
    ftp = [row for row in tests if row["test_category"] == "FTP" and row["test_procedure_code"] in FTP_PROCEDURES]
    bags = [row for row in ftp if row["fe_bag_2"] and row["fe_bag_3"]]
    specs = {name: _most_common(row[name] for row in rows) for name in _SPECS}
    car = vehicle_params.CarTests(
        fuel=fuel,
        etw_lb=specs["etw_lb"],
        rated_hp=specs["rated_hp"],
        target_a_lbf=specs["target_a_lbf"],
        target_b_lbf_per_mph=specs["target_b_lbf_per_mph"],
        target_c_lbf_per_mph2=specs["target_c_lbf_per_mph2"],
        displacement_l=specs["displacement_l"],
        nv_ratio=specs["nv_ratio"],
        drive_code=specs["drive_code"],
        ftp_mpg=_harmonic_mean(row["fe"] for row in ftp),
        ftp_bag2_mpg=_harmonic_mean(row["fe_bag_2"] for row in bags),
        ftp_bag3_mpg=_harmonic_mean(row["fe_bag_3"] for row in bags),
        hwy_mpg=_harmonic_mean(row["fe"] for row in tests if row["test_category"] == "HWY"),
        us06_mpg=_harmonic_mean(row["fe"] for row in tests if row["test_category"] == "US06"),
    )
    return {
        "test_vehicle_id": rows[0]["test_vehicle_id"],
        "configuration": rows[0]["configuration"],
        "fuel": fuel,
        "fuel_description": _most_common(row["fuel"] for row in tests),
        "row_count": len(rows),
        "specs": specs,
        "tests": car,
        "params": vehicle_params.compute(car),
    }


def _typical(variants: list[dict]) -> dict:
    for fuel in ("gasoline", "diesel"):
        candidates = [v for v in variants if v["params"].supported and v["fuel"] == fuel]
        # automatics before manuals: almost every car sold in the US is an automatic
        candidates = [v for v in candidates if v["specs"]["transmission_code"] != "M"] or candidates
        if candidates:
            # sorted() is stable, so equal fuel use keeps the test vehicle order
            candidates = sorted(candidates, key=lambda v: 0.55 / v["tests"].ftp_mpg + 0.45 / v["tests"].hwy_mpg if v["tests"].ftp_mpg else 0.45 / v["tests"].hwy_mpg)
            return candidates[(len(candidates) - 1) // 2]
    return max(variants, key=lambda v: v["row_count"])  # nothing the model supports: the most-tested configuration


def _variant_summary(variant: dict, typical: bool) -> dict:
    specs, params = variant["specs"], variant["params"]
    return {
        "test_vehicle_id": variant["test_vehicle_id"],
        "configuration": variant["configuration"],
        "typical": typical,
        "fuel": variant["fuel"],
        "displacement_l": specs["displacement_l"],
        "cylinders": specs["cylinders"],
        "rated_hp": specs["rated_hp"],
        "transmission": specs["transmission"],
        "gears": specs["gears"],
        "drive": specs["drive"],
        "etw_lb": specs["etw_lb"],
        "lab_mpg": params.lab_mpg,
        "supported": params.supported,
        "parameters": params.values,
        "fit_error": params.fit_error,
        "flags": params.flags,
    }


def _most_common(values):
    counts = Counter(value for value in values if value is not None)
    return counts.most_common(1)[0][0] if counts else None


def _harmonic_mean(values) -> float | None:
    """Average fuel economy over several tests: average the fuel per mile, not the MPG."""
    mpg = [value for value in values if value and value > 0]
    return len(mpg) / sum(1 / value for value in mpg) if mpg else None
