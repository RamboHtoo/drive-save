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
| `speed_trace` | s, mph | Phone | Required. Speeds around the event, oldest first, about 1 per second from 10 s before to 10 s after: `[{"t_s": -10, "speed_mph": 34.5}, …]`. `t_s` is seconds from `ts`, negative = before |
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

## Data still to add

| Data | Status | Notes |
| --- | --- | --- |
| Vehicle weight | Planned: comes with the selected car, from the data teammate's vehicle data | Must be matchable to fueleconomy.gov's `vehicle_id` (or year, make, model and engine) so the backend can attach it to `vehicle.weight_lb` |
| Fuel price ($/gal) and electricity price ($/kWh) | Planned: the data teammate provides them | The backend adds them to the input once the format is agreed |
| Trip location | Open | Picks the regional price; trips without events have no coordinates today |
| Elevation change | Open, optional | Speeding up uphill takes extra energy; braking downhill is often unavoidable. The phone can measure it with GPS altitude or the barometer |
| Road-load coefficients A, B, C | Open, optional | The force needed to keep moving at speed v: F = A + B·v + C·v². Separates the energy normal driving needs from waste. Listed in the EPA Test Car List next to the test weight |
| Idle time, stop count, time at high speed, event confidence, temperature, load | Open, could | Each shifts efficiency a little |
