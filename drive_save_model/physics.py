"""Notion scenario equations, not a fuel-flow sensor or a safety assessment."""
from pathlib import Path

import numpy as np

DATA = Path(__file__).parent / "data"
G = 9.80665
MPH_TO_MPS = 0.44704
LBF_TO_N = 4.4482216152605
JOULES_PER_GALLON = 121_320_000.0  # 33.7 kWh per gasoline-equivalent US gallon
EFFICIENCY = 0.30
IDLE_GAL_PER_SECOND = 0.25 / 3600
COAST_DECEL = 0.05 * G
REFERENCE_SPEED = 65 * MPH_TO_MPS
# The Notion values above, for the 2012 Mazda5. Another car's profile carries its own in
# profile["parameters"], worked out from its EPA tests (backend/services/vehicle_params.py).
DEFAULT_PARAMETERS = {
    "marginal_wheel_efficiency": EFFICIENCY, "idle_rate": 0.25, "coast_deceleration": 0.05,
    "enrichment_start_fraction": 0.5, "enrichment_max": 0.15, "drivetrain_factor": 0.9,
    "fuel_energy": JOULES_PER_GALLON,
}


def parameters(profile):
    return {**DEFAULT_PARAMETERS, **profile.get("parameters", {})}


def road_load(v, profile):
    a, b, c = (profile["road_load_si"][key] for key in ("a_n", "b_n_per_mps", "c_n_per_mps2"))
    return a + b * v + c * v * v


def fuel_per_meter(v, profile):
    if v <= 0:
        raise ValueError("Steady-speed fuel per metre is undefined at zero speed")
    p = parameters(profile)
    return road_load(v, profile) / (p["marginal_wheel_efficiency"] * p["fuel_energy"]) + p["idle_rate"] / 3600 / v


def brake_scenario(v1, v2, duration, profile):
    coast = parameters(profile)["coast_deceleration"] * G
    distance_you = (v1 + v2) / 2 * duration
    distance_twin = (v1 * v1 - v2 * v2) / (2 * coast)
    extra = max(0.0, distance_twin - distance_you)
    return {"fuel_gal": extra * fuel_per_meter(v1, profile),
            "extra_cruise_distance_m": extra, "preceding_seconds": extra / v1,
            "twin_duration_s": (v1 - v2) / coast}


def _enrichment(fraction, p):
    start = p["enrichment_start_fraction"]
    return p["enrichment_max"] * np.clip((fraction - start) / (1 - start), 0, 1)


def acceleration_scenario(v1, v2, duration, peak_g, profile):
    p = parameters(profile)
    mean = (v1 + v2) / 2
    energy = 0.5 * profile["mass_kg"] * (v2 * v2 - v1 * v1) + road_load(mean, profile) * mean * duration
    peak_power = (profile["mass_kg"] * G * peak_g + road_load(v2, profile)) * v2
    fraction = peak_power / (p["drivetrain_factor"] * 745.7 * profile["rated_horsepower"])
    enrichment = float(_enrichment(fraction, p))
    return {"fuel_gal": enrichment * energy / (p["marginal_wheel_efficiency"] * p["fuel_energy"]),
            "energy_j": energy, "estimated_peak_power_fraction": fraction,
            "enrichment_fraction": enrichment}


def high_speed_scenario(time, speed, excluded, profile):
    """Split at every event boundary; never price overlapping seconds twice.

    Each remaining piece uses the Notion midpoint speed/length approximation.
    The 65 mph reference is a comparison assumption, not a recommended speed.
    """
    fuel = seconds_saved = distance = 0.0
    for t0, t1, v0, v1 in zip(time[:-1], time[1:], speed[:-1], speed[1:]):
        cuts = sorted({float(t0), float(t1)} | {x for a, b in excluded for x in (a, b) if t0 < x < t1})
        for left, right in zip(cuts[:-1], cuts[1:]):
            mid = (left + right) / 2
            if any(a <= mid < b for a, b in excluded):
                continue
            v = float(v0 + (v1 - v0) * (mid - t0) / (t1 - t0))
            if v <= REFERENCE_SPEED:
                continue
            dx = v * (right - left)
            fuel += dx * max(0.0, fuel_per_meter(v, profile) - fuel_per_meter(REFERENCE_SPEED, profile))
            seconds_saved += dx * (1 / REFERENCE_SPEED - 1 / v)
            distance += dx
    return {"fuel_gal": fuel, "uninterrupted_time_difference_s": seconds_saved,
            "priced_distance_m": distance, "reference_speed_mph": 65}


def diagnostic_cycle_fuel(time, speed, profile):
    """Uncalibrated Willans integration for lab comparisons ONLY.

    Zero fuel requires both deceleration and non-positive wheel power in this
    assumed scenario. Idle explicitly consumes fuel. No cold-start/gear model.
    """
    p = parameters(profile)
    dt = np.diff(time)
    v = (speed[:-1] + speed[1:]) / 2
    acceleration = np.diff(speed) / dt
    power = (profile["mass_kg"] * acceleration + road_load(v, profile)) * v
    fraction = np.maximum(power, 0) / (p["drivetrain_factor"] * 745.7 * profile["rated_horsepower"])
    enrichment = _enrichment(fraction, p)
    rate = p["idle_rate"] / 3600 + np.maximum(power, 0) * (1 + enrichment) / (p["marginal_wheel_efficiency"] * p["fuel_energy"])
    rate[(acceleration < 0) & (power <= 0) & (v > 0)] = 0
    return float(np.sum(rate * dt))
