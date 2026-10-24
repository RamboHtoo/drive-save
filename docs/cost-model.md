# Cost model contract

The cost model turns a trip's harsh events into dollars. The backend gathers the inputs, calls the model for every receipt, and turns the output into the receipt the app shows. The analytics teammate owns the model; until it lands, a placeholder charges a flat $1 per event.

## Where it plugs in

`estimate()` in [`backend/services/cost_model.py`](../backend/services/cost_model.py):

```python
def estimate(inputs: CostModelInput) -> CostModelOutput: ...
```

Replace its body, or import your function there, and keep the signature. The schemas live in [`backend/models/cost_model.py`](../backend/models/cost_model.py). The tests in `backend/tests/test_api.py` check that every field reaches the model.

## Real inputs to build against

- [`fixtures/sample-cost-input.json`](../fixtures/sample-cost-input.json): a complete input for the sample trip in a 2020 Honda Civic 4Dr, with real fueleconomy.gov data.
- `GET /trips/{trip_id}/cost-input` on the live server returns exactly what the model receives for any trip you uploaded.

## Input

### `trip`

| Field | Unit | Source |
| --- | --- | --- |
| `trip_id` | | Backend |
| `started_at`, `ended_at` | UTC | Phone |
| `duration_s` | s | Derived: `ended_at` − `started_at` |
| `distance_mi` | mi | Phone |
| `avg_speed_mph` | mph | Phone |

### `events[]`, in trip order

| Field | Unit | Source | Notes |
| --- | --- | --- | --- |
| `index` | | Backend | Position in the trip; costs must come back in the same order |
| `type` | | Phone | `harsh_brake`, `rapid_accel` or `sharp_turn` |
| `ts` | UTC | Phone | |
| `speed_before_mph`, `speed_after_mph` | mph | Phone (GPS) | |
| `speed_change_mph` | mph | Derived | After − before; negative while slowing |
| `avg_speed_mph` | mph | Derived | Mean of before and after: the speed during the event |
| `duration_s` | s | Phone | Optional |
| `peak_g` | g | Phone | Forward/backward for brake and accel, sideways for turns |
| `mean_accel_g` | g | Derived | Speed change ÷ duration; negative while slowing; null without `duration_s` |
| `heading_change_deg` | degrees | Phone | How far the car turned; `sharp_turn` only; optional |
| `lat`, `lng` | degrees | Phone | Optional |

Optional fields can be null, so the model needs a fallback for each.

### `vehicle`

A snapshot of the car selected when the trip was uploaded, from fueleconomy.gov. Null if the driver hasn't picked a car.

| Field | Unit | Notes |
| --- | --- | --- |
| `vehicle_id`, `year`, `make`, `model` | | |
| `vehicle_class` | | EPA size class, for example "Midsize Cars" |
| `fuel_type` | | For example "Regular Gasoline", "Premium Gasoline", "Diesel", "Electricity" |
| `powertrain` | | "Hybrid", "Plug-in Hybrid", "EV", "FCV" and so on; null for a regular gas car. Hybrids and EVs recover braking energy |
| `transmission`, `drive`, `cylinders` | | |
| `engine_displacement_l` | L | |
| `mpg_city`, `mpg_hwy`, `mpg_combined` | mi/gal | MPGe for electric and hydrogen cars |
| `kwh_per_100mi` | kWh/100 mi | Electric cars only |
| `epa_annual_fuel_cost_usd` | USD/yr | EPA's estimate |
| `weight_lb`, `weight_source` | lb | **Always null today**: fueleconomy.gov has no weight data |
| `source_url` | | The fueleconomy.gov record |

## Output

| Field | Type | Rules |
| --- | --- | --- |
| `model_name` | string | Shown on the receipt as `cost_model` |
| `event_costs_usd` | list of numbers | Exactly one per input event, in the same order. The backend rejects anything else |
| `assumptions` | list | Every constant or data source used: `key`, `value`, `unit`, `source_url`, `as_of`, `is_estimate`. The receipt shows these to the user |

## Data the model will probably need that we don't collect yet

| Priority | Data | Why | Where to get it |
| --- | --- | --- | --- |
| Must | Vehicle weight | The energy to speed up, and the energy lost when braking, scale with mass | EPA Test Car List: "Equivalent Test Weight (lbs.)", roughly curb weight plus 300 lb, matched by year, make, model and engine size |
| Must | Fuel price ($/gal), and electricity price ($/kWh) for EVs | Turns fuel or energy into dollars | EIA weekly retail gasoline prices (Pennsylvania → Central Atlantic, PADD 1B) and EIA electricity prices. The backend can fetch and pass these |
| Must | Trip location | Picks the regional price; trips without events have no coordinates today | Phone: trip start latitude/longitude |
| Should | Road-load coefficients A, B, C | Separates normal rolling resistance and air drag from avoidable energy | Same EPA Test Car List: "Target Coef A/B/C" |
| Should | Elevation change | Speeding up uphill costs more; braking downhill is less avoidable | Phone: altitude or barometer change per event |
| Should | Speed trace around each event | Lets the model compare each event against a smooth alternative | Phone: 1 Hz speeds for about 10 s before and after each event |
| Could | Idle time and stop count | Idling burns fuel without moving | Phone: time spent stopped per trip |
| Could | Time at high speed | Air drag grows with the square of speed | Phone: time above set speeds per trip |
| Could | Event confidence | Lets the model discount uncertain events | Phone: GPS accuracy and sensor quality |
| Could | Outside temperature, passengers and cargo | Cold weather, A/C and extra load lower efficiency | Weather API by place and time; ask the driver |
