# Cost model

The backend prices every trip with the data teammate's Mazda5 fuel model, [`drive_save_model`](../drive_save_model/) (how it works: [`docs/fuel-model.md`](fuel-model.md)). It runs once, when the trip is uploaded; the result is stored in Tiger Data and the receipt the app shows is read from there.

## What to know

- **One car.** The model supports a single car, the 2012 Mazda5 2.5 L automatic (FuelEconomy.gov vehicle 31284 and its EPA test data). Every trip is priced as that car, whichever car the driver picked with `PUT /users/me/vehicle`. The driver's car stays on file for models that support more cars.
- **Demo data only.** The model is experimental, so its results may only be shown as demo data, and the shared schema enforces it (`trips_math_model_demo_only`). The backend stores every crew and trip as demo (`DEMO_ONLY` in [`backend/services/cost_model.py`](../backend/services/cost_model.py)), and responses say `is_demo: true`.
- **What costs money.** Harsh braking (compared with coasting down earlier) and rapid acceleration (extra fuel at high power) have a cost. Sharp turns are coaching only and cost $0. Driving above 65 mph adds a separate high-speed cost. `avoidable_cost_usd` on the receipt is all of these together. Amounts are small: for the sample trip, about a cent per event and 10 cents for 3 minutes at 75 mph.
- **Quality gates.** The model only prices trips it can trust. A trip it can't price is still stored, as `insufficient_data` with the reason in `quality_flags`, and its receipt returns `409` `trip_not_scored` with that reason. Common reasons:
  - `event_recording_incomplete`: `events_complete` wasn't `true`
  - `missing_detector_version`: the trip has no `detector_version`
  - `invalid_event_duration`: an event has no `duration_s`
  - `missing_boundary_speed`, `gps_gap_over_three_seconds`, `valid_time_coverage_below_95_percent`: readings must start at `started_at`, end at `ended_at`, cover the trip and leave no gap over 3 s
  - `distance_mismatch_over_10_percent`: `distance_mi` must match the readings within 10%
  - `event_speed_disagrees_with_trace`: an event's `speed_before_mph` and `speed_after_mph` must match GPS within 2 m/s
  - `missing_braking_comparison_history`, `braking_cruise_scenario_unsupported`: a harsh brake needs steady driving at its starting speed just before it

  [`docs/fuel-model.md`](fuel-model.md) lists every gate.
- **Price.** The US average price of regular gasoline from EIA ($4.284/gal, week of 2026-10-19). The price, the car and every model assumption make one immutable scoring configuration, with an id derived from its contents. A new price makes a new configuration, so every driver's baseline starts again.

## Where it plugs in

[`backend/services/cost_model.py`](../backend/services/cost_model.py):

- `build_input()` gathers the trip, its readings, each event with derived values, the vehicle profile and the fuel price into a `CostModelInput` (schemas in [`backend/models/cost_model.py`](../backend/models/cost_model.py)).
- `estimate()` calls `drive_save_model.estimate_trip` and returns a `CostModelOutput`.

The backend stores the result in the same transaction as the trip: event costs in `trip_events.cost_usd`; the totals, flags and the model's full result (`model_result`) on `trips`; the configuration in `scoring_configs`; and for priced trips, `trip_metrics`, the baseline slot and the savings ledger.

`GET /trips/{trip_id}/cost-input` returns exactly what the model received for a trip. Example: [`fixtures/sample-cost-input.json`](../fixtures/sample-cost-input.json), for [`fixtures/sample-trip.json`](../fixtures/sample-trip.json), a 5-minute trip built from the model's synthetic demo trace.

## Input

### `trip`

| Field | Unit | Source |
| --- | --- | --- |
| `trip_id` | | Backend |
| `started_at`, `ended_at` | UTC | Phone |
| `duration_s` | s | Derived: `ended_at` − `started_at` |
| `distance_mi` | mi | Phone |
| `avg_speed_mph` | mph | Phone |
| `source` | | Phone | `recorded`, `replayed` or `synthetic` |
| `is_demo` | | Backend | Always `true` while the model is experimental |
| `events_complete` | | Phone | `true` only when the detector ran for the whole trip; `false` if the phone didn't say |
| `detector_version` | | Phone | e.g. `ios-0.1.0`; null if the phone didn't send it |
| `speed_samples` | see below | Phone | Every GPS speed reading the phone sent, in time order |

Each speed sample is `{"ts": "2026-10-24T20:01:00Z", "sample_seq": 0, "speed_mps": 15.199, "speed_accuracy_mps": 0.5}`: absolute UTC time, m/s, and the reading's accuracy in m/s. Invalid readings arrive with `speed_mps` and/or `speed_accuracy_mps` set to null.

### `events[]`, in trip order

| Field | Unit | Source | Notes |
| --- | --- | --- | --- |
| `index` | | Backend | Position in the trip; costs come back in the same order |
| `event_id` | | Phone | Stable UUID for the event |
| `type` | | Phone | `harsh_brake`, `rapid_accel` or `sharp_turn` |
| `ts` | UTC | Phone | When the event started |
| `detector_version` | | Phone | Version of the phone's event detector |
| `speed_before_mph`, `speed_after_mph` | mph | Phone (GPS) | |
| `speed_change_mph` | mph | Derived | After − before; negative while slowing |
| `avg_speed_mph` | mph | Derived | Mean of before and after: the speed during the event |
| `duration_s` | s | Phone | Optional in the API, required by the model |
| `peak_g` | g | Phone | Forward/backward for brake and accel, sideways for turns |
| `mean_accel_g` | g | Derived | Speed change ÷ duration; negative while slowing; null without `duration_s` |
| `heading_change_deg` | degrees | Phone | How far the car turned; `sharp_turn` only; optional. Not used by the Mazda5 model |
| `speed_samples` | m/s | Phone | The trip's readings from 10 s before to 10 s after `ts`, same shape as above |
| `speed_window_complete` | | Derived | True when there are valid readings both before and after the event |

The backend doesn't store location, so there are no coordinates.

### `vehicle`

The vehicle profile the trip is priced with: the model's 2012 Mazda5 (identity, label MPG, EPA test weight and road-load coefficients). It's the same for every trip.

### `fuel_price`

The US average retail price of regular gasoline, from the EIA weekly series: `{"key": "fuel_price", "value": 4.284, "unit": "USD/gal", "source_url": "https://www.eia.gov/…", "as_of": "2026-10-19"}`. The scoring configuration carries the same price as its `gas_price` assumption, which the receipt shows.

## Output

| Field | Type | Meaning |
| --- | --- | --- |
| `model_name` | string | Model version, `notion-mazda5-2012-auto-v1`; shown on the receipt as `cost_model` |
| `status` | string | `scored` or `insufficient_data` |
| `event_costs_usd` | list | One per input event, in the same order; null when the trip isn't priced |
| `fuel_gal` | number or null | The trip's fuel budget from label MPG, not measured fuel |
| `avoidable_usd` | number or null | The event costs plus the high-speed cost |
| `quality_flags` | list | Caveats for a priced trip, or why it couldn't be priced |
| `details` | object | The model's full result, stored as `trips.model_result` |

## Data still to add

| Data | Status | Notes |
| --- | --- | --- |
| Other cars | Open | The model supports only the Mazda5. The app already sends each driver's EPA car data, ready for a model that uses it |
| Electricity price ($/kWh) for electric cars | Open | Needed once the model supports electric cars |
| Elevation change | Open, optional | Speeding up uphill takes extra energy; braking downhill is often unavoidable. The phone can measure it with GPS altitude or the barometer |

`heading_change_deg` is stored in a `trip_events` column added by [`backend/db/002_event_details.sql`](../backend/db/002_event_details.sql), since the shared schema doesn't have it.
