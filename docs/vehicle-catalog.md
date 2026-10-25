# Vehicle list and per-car fuel model parameters

The app's car picker and every car's fuel model parameters come from EPA's Test Car List: the files in the repo's `vehicle/` folder, one per model year. The API endpoints are in [api.md](api.md#vehicles).

## What gets loaded

[`backend/scripts/load_vehicles.py`](../backend/scripts/load_vehicles.py) reads the files and fills three tables, created by [`backend/db/003_vehicle_catalog.sql`](../backend/db/003_vehicle_catalog.sql):

| Table | Contents |
| --- | --- |
| `epa_test_car_files` | Each file: name, SHA-256, model year, row count, and why it was skipped, if it was |
| `epa_test_cars` | Every row of every loaded file (74,015), each EPA column under a snake_case name. Values that don't fit their column, and columns the loader doesn't know, go to `unmapped` under the original header, so nothing is dropped |
| `vehicle_models` | The picker: one row per brand, model and model year (12,233), with the specs and fuel model parameters of a typical tested configuration, and every configuration in `variants` |

The 2007 to 2009 files are skipped. They use an older coded layout without a brand column, so their cars can't be named reliably.

The loader replaces an earlier load in one transaction. With `--if-changed` it does nothing when the same files were already loaded with the current `CATALOG_VERSION` ([`backend/services/vehicle_catalog.py`](../backend/services/vehicle_catalog.py)). Change that version whenever the list or the parameters are computed differently.

- Locally: [`backend/scripts/test-db.sh`](../backend/scripts/test-db.sh) applies the tables and loads the list.
- On Tiger Cloud: [`backend/scripts/setup-tiger.sh`](../backend/scripts/setup-tiger.sh) does the same as `tsdbadmin` (steps 3 and 4). See [deploy.md](deploy.md#connect-tiger-data-once).

## Brand and model names

EPA spells brands differently from year to year (`FORD`, `Ford`), misspells some (`BMX`, `Mecedes-Benz`), and puts models or model years in the brand column for a few rows (`Tesla Model 3`, `2022` for Lucid). [`backend/services/epa_dataset.py`](../backend/services/epa_dataset.py) maps each spelling to one brand and removes the brand from the start of model names (`MAZDA CX-5` becomes `CX-5`). Names that are a number keep it (`Polestar 2`), and Mazda's are written `MAZDA3`.

Lookups ignore case and extra spaces. Model names stay as EPA lists them, so one car can appear under more than one name across years (`CIVIC 4DR` in some years, `CIVIC 4DR SEDAN 1.5L` in others).

Left out of the picker, but kept in `epa_test_cars`: EPA's own test car, Cruise's driverless test fleet, and police and emergency vehicles.

## The typical configuration

EPA usually tests several configurations of a model year: engines, transmissions, drive layouts. The app asks only for brand, model and year, so each entry uses a typical configuration. Among those the fuel model supports, gasoline comes before diesel and automatics before manuals (almost every car sold in the US is an automatic). The typical configuration is the one with the median lab fuel use. Every configuration is kept in `variants`, with its own parameters.

## The per-car parameters

The data teammate's fuel model ([`drive_save_model/physics.py`](../drive_save_model/physics.py), [fuel-model.md](fuel-model.md)) uses constants that the Notion cost model set for one car, the 2012 Mazda5. [`backend/services/vehicle_params.py`](../backend/services/vehicle_params.py) works out the ones that differ between cars from each car's own EPA rows. The keys match the model's assumption keys.

| Parameter | Mazda5 (model) | How it's worked out for each car |
| --- | --- | --- |
| Mass, road load A/B/C | 1701 kg, EPA coefficients | The car's EPA test weight and coast-down coefficients, as the model does for the Mazda5 |
| `idle_rate` | 0.25 gal/h | The model's 0.25 gal/h for a 2.5 L engine, scaled by the car's displacement |
| `marginal_wheel_efficiency` | 0.30 | Fitted so that the model's own fuel equation (`diagnostic_cycle_fuel`) comes closest to the car's hot-start city (UDDS, from FTP bags 2 and 3) and highway (HWFET) lab results. For the Mazda5 the fit gives 0.30, the Notion value |
| `coast_deceleration` | 0.05 g | Road load at 30 mph plus engine braking. Engine braking scales with displacement times N/V ratio (engine rpm per mph), set so that the Mazda5 keeps 0.05 g |
| `drivetrain_factor` | 0.9 | Assumed by drive layout: front-wheel 0.90, rear-wheel 0.88, all-wheel and four-wheel 0.85 |
| `fuel_energy` | 121.32 MJ/gal | Gasoline as in the model. Diesel: 128,488 Btu/gal (AFDC lower heating value) |
| `enrichment_start_fraction`, `enrichment_max` | 0.5, 0.15 | Kept. Enrichment still differs between cars through their rated horsepower |

Fitting both idle rate and efficiency to the two tests was tried first. Almost half the cars then got efficiencies above 0.5, which a gasoline engine can't reach, because the model's constant idle rate can't follow how engine friction grows with speed. With the idle rate fixed, 90% of the supported configurations that aren't hybrids land between 0.25 and 0.38.

The aggressive US06 test doesn't set `enrichment_max`. The model already misses some US06 fuel for other reasons (it's 13% low on the Mazda5's city test, 9% high on its highway test), so a fit would put all of that into enrichment. `fit_error` in `vehicle_models` and `variants` shows how far the fitted model is from each lab test, US06 included.

`mpg` is the window sticker estimated from the lab FTP and HWFET results with EPA's derived 5-cycle equations (40 CFR 600.210-12, 2008 coefficients). For the 2012 Mazda5 configuration the model uses, it gives 20.8 city and 28.7 highway; the sticker says 21 and 28. EPA revised the equations for model year 2017, which can make newer cars' estimates 1 to 2 MPG high.

## What isn't supported

`supported` is `false`, and `parameters` empty, for:

- electric, hydrogen, CNG and LPG cars, and configurations tested only on E85 (`electricity_not_modeled` and similar flags)
- configurations without a city or highway lab result, or without test weight, horsepower and road load
- 38 configurations (14 picker entries) whose tests don't fit the model at all (`tests_do_not_fit_the_model`)

Of the 25,813 tested configurations, 23,084 are supported; of the 12,233 picker entries, 10,977.

Hybrids and plug-ins are supported but flagged `drives_with_engine_off`: their fitted efficiency is above 0.45 because the engine is often off, which the model's physics doesn't describe.

## Limits

These parameters are estimates from a few lab tests run through the model's simplified physics, not measurements of anyone's car on the road. The test weight is a standard load, not the driver's. The current fuel model still prices every trip as the 2012 Mazda5; using these parameters needs the data teammate's model to accept other vehicle profiles.
