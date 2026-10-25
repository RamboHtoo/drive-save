"""Per-car parameters for the data teammate's fuel model, from the car's EPA lab tests.

drive_save_model/physics.py prices driving with constants that the Notion cost model
chose for one car, the 2012 Mazda5. compute() works out the ones that differ between
cars from a car's own rows in the EPA Test Car List:

- idle_rate: the model's 0.25 gal/h for the Mazda5's 2.5 L engine, scaled by
  displacement.
- marginal_wheel_efficiency: fitted so that the model's own fuel equation
  (physics.diagnostic_cycle_fuel: the idle rate whenever fuel isn't cut, plus
  positive wheel energy / (efficiency x fuel energy)) comes closest to the car's
  hot-start city result (UDDS, from FTP bags 2 and 3) and its highway result
  (HWFET), in relative terms. For the Mazda5 this gives 0.30, the Notion value.
- coast_deceleration: the car's road load at 30 mph plus engine braking, which scales
  with displacement x N/V ratio (engine rpm per mph). The engine-braking constant is
  set so that the Mazda5 keeps the model's 0.05 g.
- drivetrain_factor: by drive layout. fuel_energy: by fuel.
- enrichment_start_fraction and enrichment_max keep the model's values. Enrichment
  still differs between cars through rated horsepower. The aggressive US06 test can't
  set them: the model misses other US06 fuel too, so a fit would put all of it there.

Mass and road load come from the test weight and coast-down coefficients, as in the
model's Mazda5 profile. fit_error says how far the fitted model is from each lab
result. These are estimates from a few lab tests run through the model's simplified
physics, not measurements of the car on the road.
"""

import json
from dataclasses import dataclass, field

import numpy as np
from drive_save_model import physics
from drive_save_model.estimator import reference_profile
from drive_save_model.validation import load_cycle

LB_TO_KG = 0.45359237
HP_TO_W = 745.7
METERS_PER_MILE = 1609.344
DIESEL_JOULES_PER_GALLON = 128_488 * 1055.05585  # AFDC lower heating value of No. 2 diesel, 128,488 Btu/gal
FUEL_ENERGY = {"gasoline": physics.JOULES_PER_GALLON, "diesel": DIESEL_JOULES_PER_GALLON}

UDDS_FIRST_BAG_S = 505  # FTP bags 1 (cold) and 3 (hot) cover the UDDS's first 505 s, bag 2 the rest
# The bags' hot-start UDDS is 0.92-1.13x the FTP composite for 99.9% of cars. Further off, a bag
# is mistyped (2021 GMC Canyon 4WD: 2.5x) and the composite is used instead.
BAGS_TO_FTP_RANGE = (0.8, 1.3)
COAST_REFERENCE_MPH = 30
ENRICHMENT_START = 0.5  # the model's values: physics.acceleration_scenario and diagnostic_cycle_fuel
ENRICHMENT_MAX = 0.15
DRIVETRAIN = {"F": 0.90, "R": 0.88, "A": 0.85, "4": 0.85, "P": 0.85}  # front-wheel drive keeps the model's 0.9
DRIVE_NAMES = {"F": "front-wheel", "R": "rear-wheel", "A": "all-wheel", "4": "four-wheel", "P": "part-time four-wheel"}
# Engine rpm per mph in top gear. Outside this range EPA's value is a typo (the 2015-2017
# BMW M3 says 216.5), so the car gets the Mazda5's engine-braking deceleration instead.
NV_RATIO_RANGE = (5, 80)
# Gasoline and diesel engines fit between 0.2 and 0.4. Higher means driving with the engine
# off (hybrids, plug-ins), which the model's physics doesn't describe; outside the
# supported range the tests and the model disagree too much to use.
CONVENTIONAL_EFFICIENCY_MAX = 0.45
SUPPORTED_EFFICIENCY = (0.15, 0.80)


def _reference_car() -> tuple[float, float, float]:
    """(engine braking N per litre per rpm/mph, its deceleration in m/s^2, idle gal/h per litre) for the model's Mazda5."""
    profile = reference_profile()
    rows = json.loads((physics.DATA / "epa_2012_mazda5.json").read_text())
    row = next(r for r in rows if r["Test Category"] == "HWY")  # the row reference_profile() reads
    litres, nv_ratio = float(row["Test Veh Displacement (L)"]), float(row["N/V Ratio"])
    engine_force = physics.COAST_DECEL * profile["mass_kg"] - physics.road_load(COAST_REFERENCE_MPH * physics.MPH_TO_MPS, profile)
    return engine_force / (litres * nv_ratio), engine_force / profile["mass_kg"], physics.IDLE_GAL_PER_SECOND * 3600 / litres


ENGINE_BRAKE_N, REFERENCE_ENGINE_BRAKE, IDLE_GAL_PER_HOUR_PER_LITRE = _reference_car()


@dataclass(frozen=True)
class _Cycle:
    dt: np.ndarray
    v: np.ndarray  # mean speed of each step, m/s
    a: np.ndarray  # acceleration of each step, m/s^2
    miles: np.ndarray  # distance of each step
    start: np.ndarray  # when each step starts, s

    @classmethod
    def load(cls, name: str) -> "_Cycle":
        time, speed = load_cycle(name)
        dt = np.diff(time)
        v = (speed[:-1] + speed[1:]) / 2
        return cls(dt, v, np.diff(speed) / dt, v * dt / METERS_PER_MILE, time[:-1])


_CYCLES = {name: _Cycle.load(name) for name in ("udds", "hwfet", "us06")}


@dataclass
class CarTests:
    """One tested configuration of a car: its specs and lab fuel economy (MPG) by test."""

    fuel: str  # gasoline, diesel, e85, electricity, hydrogen, cng, lpg or other
    etw_lb: float | None
    rated_hp: float | None
    target_a_lbf: float | None
    target_b_lbf_per_mph: float | None
    target_c_lbf_per_mph2: float | None
    displacement_l: float | None = None
    nv_ratio: float | None = None
    drive_code: str | None = None
    ftp_mpg: float | None = None  # FTP composite, cold and hot start
    ftp_bag2_mpg: float | None = None
    ftp_bag3_mpg: float | None = None
    hwy_mpg: float | None = None
    us06_mpg: float | None = None


@dataclass
class CarParameters:
    supported: bool
    values: dict[str, float] | None  # parameter key -> value in the model's units; None when not supported
    parameters: list[dict]  # the same with unit and how each was found
    flags: list[str] = field(default_factory=list)
    lab_mpg: dict[str, float | None] = field(default_factory=dict)  # ftp, hot_udds, highway, us06
    fit_error: dict[str, float] | None = None  # (model - lab) / lab fuel for city, highway and us06
    label_mpg: dict[str, float] | None = None  # window-sticker estimates: city, highway, combined
    mass_kg: float | None = None
    road_load_si: dict[str, float] | None = None


def compute(tests: CarTests) -> CarParameters:
    flags: list[str] = []
    hot_udds, from_bags = _hot_udds_mpg(tests)
    result = CarParameters(False, None, [], flags, {"ftp": tests.ftp_mpg, "hot_udds": hot_udds, "highway": tests.hwy_mpg, "us06": tests.us06_mpg})
    if tests.fuel in ("gasoline", "diesel", "e85") and tests.ftp_mpg and tests.hwy_mpg:
        result.label_mpg = label_mpg(tests.ftp_mpg, tests.hwy_mpg)
    if tests.fuel not in FUEL_ENERGY:
        flags.append(f"{tests.fuel}_not_modeled")
        return result
    road = (tests.target_a_lbf, tests.target_b_lbf_per_mph, tests.target_c_lbf_per_mph2)
    if not (tests.etw_lb and tests.etw_lb > 0 and tests.rated_hp and tests.rated_hp > 0 and None not in road):
        flags.append("missing_weight_power_or_road_load")
        return result
    if not (tests.hwy_mpg and tests.hwy_mpg > 0 and hot_udds and hot_udds > 0):
        flags.append("missing_city_or_highway_test")
        return result
    if not from_bags:
        flags.append("city_test_includes_cold_start")  # the FTP composite stands in for a hot UDDS

    mass = tests.etw_lb * LB_TO_KG
    road_si = {
        "a_n": road[0] * physics.LBF_TO_N,
        "b_n_per_mps": road[1] * physics.LBF_TO_N / physics.MPH_TO_MPS,
        "c_n_per_mps2": road[2] * physics.LBF_TO_N / physics.MPH_TO_MPS**2,
    }
    result.mass_kg, result.road_load_si = mass, road_si
    drivetrain = DRIVETRAIN.get(tests.drive_code or "", 0.9)
    if tests.drive_code not in DRIVETRAIN:
        flags.append("drive_layout_unknown")
    litres = tests.displacement_l if tests.displacement_l and tests.displacement_l > 0 else None
    if litres is None:
        flags.append("idle_rate_without_displacement")
    idle = (IDLE_GAL_PER_HOUR_PER_LITRE * litres if litres else physics.IDLE_GAL_PER_SECOND * 3600) / 3600

    work = {name: _work(cycle, mass, road_si, drivetrain * HP_TO_W * tests.rated_hp) for name, cycle in _CYCLES.items()}
    lab = {
        "city": float(_CYCLES["udds"].miles.sum()) / hot_udds,
        "highway": float(_CYCLES["hwfet"].miles.sum()) / tests.hwy_mpg,
        "us06": float(_CYCLES["us06"].miles.sum()) / tests.us06_mpg if tests.us06_mpg and tests.us06_mpg > 0 else None,
    }
    cycles = {"city": "udds", "highway": "hwfet", "us06": "us06"}
    # Fuel over a cycle = idle x fueled seconds + k x wheel energy, where k = 1 / (efficiency x fuel energy).
    # k minimizes the squared relative error over the city and highway tests.
    points = [(work[cycles[test]], lab[test]) for test in ("city", "highway")]
    k = sum(w / f * (1 - idle * t / f) for (t, w), f in points) / sum((w / f) ** 2 for (t, w), f in points)
    energy = FUEL_ENERGY[tests.fuel]
    efficiency = 1 / (k * energy) if k > 0 else 0.0
    result.fit_error = {test: (idle * work[cycles[test]][0] + k * work[cycles[test]][1]) / gallons - 1 for test, gallons in lab.items() if gallons}
    if not SUPPORTED_EFFICIENCY[0] <= efficiency <= SUPPORTED_EFFICIENCY[1]:
        flags.append("tests_do_not_fit_the_model")
        return result
    if efficiency > CONVENTIONAL_EFFICIENCY_MAX:
        flags.append("drives_with_engine_off")  # hybrid or plug-in: the model's physics assumes the engine always runs

    nv_ratio = tests.nv_ratio if tests.nv_ratio and NV_RATIO_RANGE[0] <= tests.nv_ratio <= NV_RATIO_RANGE[1] else None
    if not (litres and nv_ratio):
        flags.append("engine_braking_from_reference_car")
    result.supported = True
    result.values = {
        "marginal_wheel_efficiency": round(efficiency, 6),
        "idle_rate": round(idle * 3600, 6),
        "coast_deceleration": round(_coast_deceleration_g(mass, road_si, litres, nv_ratio), 6),
        "enrichment_start_fraction": ENRICHMENT_START,
        "enrichment_max": ENRICHMENT_MAX,
        "drivetrain_factor": drivetrain,
        "fuel_energy": energy,
    }
    drive = DRIVE_NAMES.get(tests.drive_code or "")
    methods = {
        "marginal_wheel_efficiency": ("fraction", "Fitted so the model's fuel equation comes closest to this car's hot-start city (UDDS) and highway (HWFET) lab results"),
        "idle_rate": (
            "US-gal/hour",
            "The model's 0.25 gal/h for its 2.5 L Mazda5, scaled by this car's displacement" if litres else "The model's value; displacement unknown",
        ),
        "coast_deceleration": (
            "g",
            "Road load at 30 mph plus engine braking scaled by displacement x N/V ratio, set so the model's 2012 Mazda5 keeps 0.05 g"
            if litres and nv_ratio
            else "Road load at 30 mph plus the 2012 Mazda5's engine braking; this car's displacement or N/V ratio is missing or implausible",
        ),
        "enrichment_start_fraction": ("rated power fraction", "The model's value; it applies to this car's own rated horsepower"),
        "enrichment_max": ("fraction", "The model's value; it applies to this car's own rated horsepower"),
        "drivetrain_factor": ("fraction", f"Assumed for {drive} drive" if drive else "The model's value; drive layout unknown"),
        "fuel_energy": (
            "J/US-gal",
            "Gasoline-equivalent gallon, as in the model" if tests.fuel == "gasoline" else "Diesel lower heating value, 128,488 Btu/gal (AFDC)",
        ),
    }
    result.parameters = [
        {"key": key, "value": result.values[key], "unit": unit, "method": method, "is_estimate": True} for key, (unit, method) in methods.items()
    ]
    return result


def label_mpg(ftp_mpg: float, hwy_mpg: float) -> dict[str, float]:
    """Window-sticker MPG estimated from lab results with EPA's derived 5-cycle equations
    (40 CFR 600.210-12, 2008 coefficients; EPA revised them for model year 2017, which
    lowers some newer cars' estimates by 1-2 MPG)."""
    city = 1 / (0.003259 + 1.1805 / ftp_mpg)
    highway = 1 / (0.001376 + 1.3466 / hwy_mpg)
    return {"city": city, "highway": highway, "combined": 1 / (0.55 / city + 0.45 / highway)}


def _hot_udds_mpg(tests: CarTests) -> tuple[float | None, bool]:
    """(MPG over a hot-start UDDS, whether the FTP bags gave it): bag 3 for its first 505 s, bag 2
    for the rest. The FTP composite stands in without bags, or when the bags disagree with it."""
    if tests.ftp_bag2_mpg and tests.ftp_bag3_mpg and tests.ftp_bag2_mpg > 0 and tests.ftp_bag3_mpg > 0:
        udds = _CYCLES["udds"]
        first = udds.start < UDDS_FIRST_BAG_S
        miles_first, miles_rest = float(udds.miles[first].sum()), float(udds.miles[~first].sum())
        hot = (miles_first + miles_rest) / (miles_first / tests.ftp_bag3_mpg + miles_rest / tests.ftp_bag2_mpg)
        if not tests.ftp_mpg or BAGS_TO_FTP_RANGE[0] <= hot / tests.ftp_mpg <= BAGS_TO_FTP_RANGE[1]:
            return hot, True
    return tests.ftp_mpg, False


def _work(cycle: _Cycle, mass: float, road: dict[str, float], usable_power_w: float) -> tuple[float, float]:
    """physics.diagnostic_cycle_fuel taken apart for one car over one cycle:
    (seconds of fuel flow, wheel energy in J with the model's enrichment added)."""
    force = road["a_n"] + road["b_n_per_mps"] * cycle.v + road["c_n_per_mps2"] * cycle.v**2
    power = (mass * cycle.a + force) * cycle.v
    positive = np.maximum(power, 0)
    enrichment = ENRICHMENT_MAX * np.clip((positive / usable_power_w - ENRICHMENT_START) / ENRICHMENT_START, 0, 1)
    fueled = ~((cycle.a < 0) & (power <= 0) & (cycle.v > 0))  # no fuel while coasting down
    return float(cycle.dt[fueled].sum()), float((positive * (1 + enrichment) * cycle.dt)[fueled].sum())


def _coast_deceleration_g(mass: float, road: dict[str, float], litres: float | None, nv_ratio: float | None) -> float:
    v = COAST_REFERENCE_MPH * physics.MPH_TO_MPS
    road_force = road["a_n"] + road["b_n_per_mps"] * v + road["c_n_per_mps2"] * v * v
    engine_force = ENGINE_BRAKE_N * litres * nv_ratio if litres and nv_ratio else REFERENCE_ENGINE_BRAKE * mass
    return (road_force + engine_force) / (mass * physics.G)
