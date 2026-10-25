"""The vehicle list's building blocks: reading EPA files, naming cars, and the per-car
fuel model parameters. No database needed; the files are small ones written here."""

import csv
import json

import openpyxl
import pytest
from drive_save_model import physics
from drive_save_model.estimator import reference_profile
from drive_save_model.validation import load_cycle

from services import epa_dataset, vehicle_catalog, vehicle_params

HEADER = [header for _, header, _ in epa_dataset.COLUMNS]
MAZDA_ROWS = json.loads((physics.DATA / "epa_2012_mazda5.json").read_text())  # the model's own car, EPA configuration 1


def mazda5(**changes) -> vehicle_params.CarTests:
    """The 2012 Mazda5 the model is built on, as CarTests."""
    ftp = next(r for r in MAZDA_ROWS if r["Test Category"] == "FTP")
    tests = vehicle_params.CarTests(
        fuel="gasoline",
        etw_lb=3750,
        rated_hp=157,
        target_a_lbf=34.059,
        target_b_lbf_per_mph=0.18979,
        target_c_lbf_per_mph2=0.023476,
        displacement_l=2.5,
        nv_ratio=33,
        drive_code="F",
        ftp_mpg=26.4,
        ftp_bag2_mpg=float(ftp["FE Bag 2"]),
        ftp_bag3_mpg=float(ftp["FE Bag 3"]),
        hwy_mpg=40.3,
        us06_mpg=24.2,
    )
    return vehicle_params.CarTests(**{**tests.__dict__, **changes})


@pytest.mark.parametrize(
    "make, model, manufacturer, expected",
    [
        ("FORD", "Escape FWD", "FOMOCO", ("Ford", "Escape FWD")),
        ("MAZDA", "MAZDA CX-5", "MAZDA", ("Mazda", "CX-5")),
        ("Mazda", "Mazda 3 DI 4-Door", "MAZDA", ("Mazda", "MAZDA3 DI 4-Door")),
        ("Polestar 2", "Polestar 2 BST edition", "Volvo", ("Polestar", "Polestar 2 BST edition")),
        ("Tesla Model 3", "Long Range", "Tesla", ("Tesla", "Model 3 Long Range")),
        ("Range Rover", "Evoque 250PS", "Jaguar Land Rover L", ("Land Rover", "Range Rover Evoque 250PS")),
        ("LINCOLN-MERCURY", "MILAN", "FOMOCO", ("Mercury", "MILAN")),
        ("2022", "Lucid Air Dream P", "Lucid USA, Inc", ("Lucid", "Air Dream P")),
        ("EPA", "Hunter Green", "EPA", (None, None)),
        ("SCOUT", "Traveler", "Scout Motors", ("Scout", "Traveler")),  # a brand the table doesn't know yet
    ],
)
def test_brand_and_model_names_are_normalized(make, model, manufacturer, expected):
    assert epa_dataset.normalize_vehicle(make, model, manufacturer) == expected


def write_csv(path, header, rows):
    with path.open("w", newline="") as f:
        csv.writer(f).writerows([header, *rows])


def epa_row(**values) -> list:
    row = {header: "" for header in HEADER}
    row.update({"Model Year": "2012", "Represented Test Veh Make": "MAZDA", "Represented Test Veh Model": "MAZDA5"}, **values)
    return [row[header] for header in HEADER]


def test_csv_and_excel_files_read_the_same_way(tmp_path):
    rows = [epa_row(**{"RND_ADJ_FE": "40.3", "Test Veh Configuration #": "1"}), epa_row(**{"RND_ADJ_FE": "n/a"})]
    write_csv(tmp_path / "12tstcar.csv", [*HEADER, "New EPA Column"], [[*rows[0], "kept"], [*rows[1], ""]])
    workbook = openpyxl.Workbook()
    workbook.active.append(HEADER)
    workbook.active.append([2012 if v == "2012" else 40.3 if v == "40.3" else 1 if v == "1" else v or None for v in rows[0]])
    workbook.save(tmp_path / "13tstcar.xlsx")

    from_csv, from_excel = epa_dataset.read_folder(tmp_path)
    assert from_csv.rows[0]["fe"] == from_excel.rows[0]["fe"] == 40.3
    assert from_csv.rows[0]["configuration"] == from_excel.rows[0]["configuration"] == 1
    assert (from_csv.rows[0]["make"], from_csv.rows[0]["model"]) == ("Mazda", "MAZDA5")
    assert from_csv.rows[0]["unmapped"] == {"New EPA Column": "kept"}  # unknown columns are kept, not dropped
    assert from_csv.rows[1]["fe"] is None and from_csv.rows[1]["unmapped"] == {"RND_ADJ_FE": "n/a"}  # so are values that don't parse
    assert from_csv.model_year == 2012 and len(from_csv.sha256) == 64


def test_2007_to_2009_files_are_skipped(tmp_path):
    write_csv(tmp_path / "07tstcar.csv", ["MDLYR_DT", "VI_MFR_CD", "CL_NM"], [["2007", "20", "RAM 1500 PICKUP 2WD"]])
    (legacy,) = epa_dataset.read_folder(tmp_path)
    assert legacy.rows == [] and "2007-2009" in legacy.skipped


def test_parameters_use_the_models_own_fuel_equation():
    """Taking physics.diagnostic_cycle_fuel apart gives back exactly the model's cycle fuel."""
    profile = reference_profile()
    for name in ("udds", "hwfet", "us06"):
        seconds, wheel_joules = vehicle_params._work(vehicle_params._CYCLES[name], profile["mass_kg"], profile["road_load_si"], 0.9 * 745.7 * 157)
        gallons = physics.IDLE_GAL_PER_SECOND * seconds + wheel_joules / (physics.EFFICIENCY * physics.JOULES_PER_GALLON)
        assert gallons == pytest.approx(physics.diagnostic_cycle_fuel(*load_cycle(name), profile))


def test_the_models_own_car_keeps_the_notion_values():
    car = vehicle_params.compute(mazda5())
    assert car.supported and car.flags == []
    assert car.values["marginal_wheel_efficiency"] == pytest.approx(physics.EFFICIENCY, abs=0.01)  # fitted, not copied
    assert car.values["idle_rate"] == pytest.approx(physics.IDLE_GAL_PER_SECOND * 3600)
    assert car.values["coast_deceleration"] == pytest.approx(physics.COAST_DECEL / physics.G, abs=1e-6)
    assert car.mass_kg == pytest.approx(reference_profile()["mass_kg"])
    # FuelEconomy.gov's window sticker for this car: 21 city, 28 highway
    assert car.label_mpg["city"] == pytest.approx(21, abs=1) and car.label_mpg["highway"] == pytest.approx(28, abs=1)


def test_efficiency_fit_finds_a_cars_efficiency_from_its_lab_results():
    """Lab results the model itself would give at efficiency 0.34 lead back to 0.34."""
    car = mazda5()
    mass, road = car.etw_lb * vehicle_params.LB_TO_KG, vehicle_params.compute(car).road_load_si
    mpg = {}
    for name in ("udds", "hwfet"):
        cycle = vehicle_params._CYCLES[name]
        seconds, wheel_joules = vehicle_params._work(cycle, mass, road, 0.9 * 745.7 * car.rated_hp)
        mpg[name] = cycle.miles.sum() / (0.25 / 3600 * seconds + wheel_joules / (0.34 * physics.JOULES_PER_GALLON))
    fitted = vehicle_params.compute(mazda5(ftp_mpg=mpg["udds"], ftp_bag2_mpg=mpg["udds"], ftp_bag3_mpg=mpg["udds"], hwy_mpg=mpg["hwfet"]))
    assert fitted.values["marginal_wheel_efficiency"] == pytest.approx(0.34, abs=1e-6)
    assert fitted.fit_error["city"] == pytest.approx(0, abs=1e-9) and fitted.fit_error["highway"] == pytest.approx(0, abs=1e-9)


def test_cars_the_model_cant_describe_get_no_parameters():
    electric = vehicle_params.compute(mazda5(fuel="electricity"))
    assert not electric.supported and electric.values is None and electric.flags == ["electricity_not_modeled"]
    untested = vehicle_params.compute(mazda5(hwy_mpg=None))
    assert not untested.supported and untested.flags == ["missing_city_or_highway_test"]


def test_hybrids_are_flagged():
    hybrid = vehicle_params.compute(mazda5(ftp_mpg=55, ftp_bag2_mpg=55, ftp_bag3_mpg=55, hwy_mpg=55))
    assert hybrid.supported and "drives_with_engine_off" in hybrid.flags


def test_mistyped_ftp_bags_fall_back_to_the_ftp_composite():
    typo = vehicle_params.compute(mazda5(ftp_bag2_mpg=66, ftp_bag3_mpg=74))  # 2.5x the FTP result, like the 2021 GMC Canyon 4WD
    assert typo.lab_mpg["hot_udds"] == 26.4 and typo.flags == ["city_test_includes_cold_start"]


def test_an_impossible_nv_ratio_falls_back_to_the_reference_engine_braking():
    typo = vehicle_params.compute(mazda5(nv_ratio=216.5))  # as EPA lists the 2015-2017 BMW M3
    assert typo.values["coast_deceleration"] == pytest.approx(physics.COAST_DECEL / physics.G, abs=1e-6)
    assert typo.flags == ["engine_braking_from_reference_car"]


def test_heavier_draggier_cars_coast_down_faster_and_bigger_engines_idle_more():
    base = vehicle_params.compute(mazda5()).values
    truck = vehicle_params.compute(mazda5(target_c_lbf_per_mph2=0.05, displacement_l=5.0, drive_code="4")).values
    assert truck["coast_deceleration"] > base["coast_deceleration"]
    assert truck["idle_rate"] == pytest.approx(2 * base["idle_rate"])
    assert truck["drivetrain_factor"] < base["drivetrain_factor"]


def catalog_rows(test_vehicle_id, configuration, transmission_code, hwy_mpg, **specs) -> list[dict]:
    base = {
        "make": "Mazda", "model": "MAZDA5", "model_year": 2012, "police_emergency": "N", "test_vehicle_id": test_vehicle_id,
        "configuration": configuration, "vehicle_type": "Car", "displacement_l": 2.5, "cylinders": 4, "rated_hp": 157,
        "transmission": "Manual" if transmission_code == "M" else "Automatic", "transmission_code": transmission_code, "gears": 5,
        "drive": "2-Wheel Drive, Front", "drive_code": "F", "etw_lb": 3750, "axle_ratio": 3.46, "nv_ratio": 33,
        "target_a_lbf": 34.059, "target_b_lbf_per_mph": 0.18979, "target_c_lbf_per_mph2": 0.023476,
        "fuel": "Tier 2 Cert Gasoline", "fe_bag_2": None, "fe_bag_3": None, **specs,
    }
    return [
        {**base, "test_category": "FTP", "test_procedure_code": 21, "fe": hwy_mpg - 13},
        {**base, "test_category": "HWY", "test_procedure_code": 3, "fe": hwy_mpg},
    ]


def test_epa_placeholders_for_missing_results_are_left_out():
    rows = catalog_rows("AUTO", 0, "A", 40)
    rows.append({**rows[1], "fe": 9999.9999999})  # a second highway test with no result
    (entry,) = vehicle_catalog.build(rows)
    assert entry["lab_hwy_mpg"] == 40


def test_each_model_year_shows_its_typical_automatic_and_keeps_every_configuration():
    rows = catalog_rows("MANUAL", 0, "M", 41) + catalog_rows("AUTO-A", 0, "A", 42) + catalog_rows("AUTO-B", 1, "A", 40)
    rows += catalog_rows("POLICE", 0, "A", 30, police_emergency="Y")
    (entry,) = vehicle_catalog.build(rows)
    assert entry["variant_count"] == 3  # the police car isn't in the picker
    # Not the manual. Of the two automatics, the lower median: the one that uses less fuel.
    assert entry["test_vehicle_id"] == "AUTO-A"
    assert [v["test_vehicle_id"] for v in entry["variants"] if v["typical"]] == ["AUTO-A"]
    assert entry["id"] == vehicle_catalog.vehicle_id("MAZDA", "mazda5", 2012)  # stable across reloads
    assert entry["supported"] and entry["vehicle_profile"]["road_load_original"]["a_lbf"] == 34.059
