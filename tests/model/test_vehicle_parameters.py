"""Pricing another car: its profile carries its own parameters (physics.DEFAULT_PARAMETERS keys)."""

from copy import deepcopy

from drive_save_model import estimate_trip, reference_profile, scoring_config
from drive_save_model.physics import DEFAULT_PARAMETERS, parameters
from drive_save_model.validation import example_payload


def other_car(**changes):
    profile = reference_profile()
    profile.update(id="epa-2020-TEST-config0", name="2020 Test Car", parameters={**DEFAULT_PARAMETERS, **changes},
                   parameters_source_url="https://example.test/epa-test-cars")
    return profile


def priced_as(profile):
    payload = example_payload("demo")
    payload["vehicle_profile"] = deepcopy(profile)
    payload["scoring_config"] = scoring_config(3.50, price_as_of="2026-10-24", vehicle_profile=profile)
    return payload


def test_the_mazda5_keeps_the_notion_values():
    assert parameters(reference_profile()) == DEFAULT_PARAMETERS
    assert scoring_config(3.5, price_as_of="2026-10-24") == scoring_config(3.5, price_as_of="2026-10-24", vehicle_profile=reference_profile())


def test_another_car_is_priced_with_its_own_parameters():
    mazda5 = estimate_trip(**example_payload("demo"))
    same_values = estimate_trip(**priced_as(other_car()))
    assert same_values["status"] == "scored" and abs(same_values["avoidable_usd"] - mazda5["avoidable_usd"]) < 1e-12

    efficient = estimate_trip(**priced_as(other_car(marginal_wheel_efficiency=0.4)))
    slow_coasting = estimate_trip(**priced_as(other_car(coast_deceleration=0.04)))
    assert efficient["avoidable_usd"] < same_values["avoidable_usd"]
    brake = lambda r: r["model_details"]["cost_breakdown_usd"]["harsh_brake"]
    assert brake(slow_coasting) > brake(same_values)  # coasting farther makes more of the braking avoidable

    shown = {a["key"]: a for a in efficient["model_details"]["assumptions"]}
    assert shown["marginal_wheel_efficiency"]["value"] == 0.4
    assert shown["marginal_wheel_efficiency"]["source_url"] == "https://example.test/epa-test-cars"


def test_a_diesel_car_is_priced_in_diesel():
    diesel = other_car(fuel_energy=135_562_016.0)
    diesel["fuel_type"] = "diesel"
    payload = priced_as(diesel)
    payload["scoring_config"] = scoring_config(6.276, price_as_of="2026-10-19", vehicle_profile=diesel)
    result = estimate_trip(**payload)
    prices = {a["key"]: a["value"] for a in result["model_details"]["assumptions"] if a["key"].endswith("_price")}
    assert prices == {"diesel_price": 6.276}
    assert abs(result["estimated_trip_cost_usd"] - result["fuel_gal"] * 6.276) < 1e-12


def test_a_car_needs_every_parameter_and_its_own_configuration():
    missing = priced_as(other_car())
    del missing["vehicle_profile"]["parameters"]["fuel_energy"]
    assert estimate_trip(**missing)["quality_flags"] == ["unsupported_vehicle_profile"]

    impossible = priced_as(other_car())
    impossible["vehicle_profile"]["parameters"]["idle_rate"] = float("nan")
    assert estimate_trip(**impossible)["quality_flags"] == ["unsupported_vehicle_profile"]

    borrowed = priced_as(other_car())
    borrowed["vehicle_profile"]["parameters"]["marginal_wheel_efficiency"] = 0.5
    assert estimate_trip(**borrowed)["quality_flags"] == ["scoring_config_mismatch"]
