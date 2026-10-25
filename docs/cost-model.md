# Cost model contract

The cost model turns a trip's harsh events into dollars. The backend gathers the inputs, calls the model once when a trip is uploaded, and stores the result in Tiger Data; the receipt the app shows is read from there. The analytics teammate owns the model; until it lands, a placeholder charges a flat $1 per event and assumes 25 mpg to fill in fuel used.

## Where it plugs in

`estimate()` in [`backend/services/cost_model.py`](../backend/services/cost_model.py):

```python
def estimate(inputs: CostModelInput) -> CostModelOutput: ...
```

Replace its body, or import your function there, and keep the signature. The schemas live in [`backend/models/cost_model.py`](../backend/models/cost_model.py). The tests in `backend/tests/test_api.py` check that every field reaches the model.

## Real inputs to build against

- [`fixtures/sample-cost-input.json`](../fixtures/sample-cost-input.json): a complete input for the sample trip, with the car from [`fixtures/sample-vehicle.json`](../fixtures/sample-vehicle.json) (a real EPA Test Car List row).
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
| `events_complete` | | Phone | `true` only when the detector ran for the whole trip; `false` if the phone didn't say |
| `detector_version` | | Phone | e.g. `ios-0.1.0`; null if the phone didn't send it |
| `speed_samples` | see below | Phone | Every GPS speed reading the phone sent, in time order |

Each speed sample is `{"ts": "2026-10-24T20:07:02Z", "sample_seq": 0, "speed_mps": 15.423, "speed_accuracy_mps": 0.5}`: absolute UTC time, m/s, and the reading's accuracy in m/s. Invalid readings arrive with `speed_mps` and/or `speed_accuracy_mps` set to null.

### `events[]`, in trip order

| Field | Unit | Source | Notes |
| --- | --- | --- | --- |
| `index` | | Backend | Position in the trip; costs must come back in the same order |
| `event_id` | | Phone | Stable UUID for the event |
| `type` | | Phone | `harsh_brake`, `rapid_accel` or `sharp_turn` |
| `ts` | UTC | Phone | When the event started |
| `detector_version` | | Phone | Version of the phone's event detector |
| `speed_before_mph`, `speed_after_mph` | mph | Phone (GPS) | |
| `speed_change_mph` | mph | Derived | After − before; negative while slowing |
| `avg_speed_mph` | mph | Derived | Mean of before and after: the speed during the event |
| `duration_s` | s | Phone | Optional |
| `peak_g` | g | Phone | Forward/backward for brake and accel, sideways for turns |
| `mean_accel_g` | g | Derived | Speed change ÷ duration; negative while slowing; null without `duration_s` |
| `heading_change_deg` | degrees | Phone | How far the car turned; `sharp_turn` only; optional |
| `speed_samples` | m/s | Phone | The trip's readings from 10 s before to 10 s after `ts`, same shape as above |
| `speed_window_complete` | | Derived | True when there are valid readings both before and after the event. False means the phone left a gap; the event is kept, so decide how to price it |

Optional fields can be null, so the model needs a fallback for each. The backend doesn't store location, so there are no coordinates.

### `fuel_price`

The US average retail price of regular gasoline, from the EIA weekly series, in the same shape as an assumption: `{"key": "fuel_price", "value": 4.284, "unit": "USD/gal", "source_url": "https://www.eia.gov/…", "as_of": "2026-10-19"}`. Copy it into your `assumptions` so the receipt shows the price used.

### `vehicle`

The car's data exactly as the app sent it with `PUT /users/me/vehicle`, as of when the trip was uploaded. Null if the app never sent one. The backend passes it through without reading it, so you and the app agree on the field names and units. Example: [`fixtures/sample-vehicle.json`](../fixtures/sample-vehicle.json), built from a real EPA Test Car List row (2026 Honda Civic 4DR, 1.5 L, manual): test weight 3,250 lb and road-load coefficients A, B, C (the force needed to keep moving at speed v is A + B·v + C·v²).

**Heads-up on the EPA fuel economy numbers:** the Test Car List's `RND_ADJ_FE` values are lab test-cycle results, well above real-world (window-sticker) MPG. For the car above, the file shows 35.8 (city cycle) and 56.3 (highway cycle), while fueleconomy.gov's label for the same car is 27 city / 37 highway / 31 combined. Using the lab numbers as-is would underestimate fuel use by roughly a quarter to a third.

## Output

| Field | Type | Rules |
| --- | --- | --- |
| `model_name` | string | Shown on the receipt as `cost_model` |
| `event_costs_usd` | list of numbers | Exactly one per input event, in the same order. The backend rejects anything else |
| `fuel_gal` | number or null | Fuel the whole trip used. The database (`trips.fuel_gal`) requires it for scored trips. Return null only when the trip can't be priced: it's then stored as `insufficient_data`, without costs |
| `assumptions` | list | Every constant or data source used: `key`, `value`, `unit`, `source_url`, `as_of`, `is_estimate`. The receipt shows these to the user |

## Data still to add

| Data | Status | Notes |
| --- | --- | --- |
| Electricity price ($/kWh) for electric cars | Open | Fuel price is the US average today; electric cars need an electricity price too |
| Elevation change | Open, optional | Speeding up uphill takes extra energy; braking downhill is often unavoidable. The phone can measure it with GPS altitude or the barometer |
| Idle time, stop count, time at high speed, temperature, load | Open, could | Each shifts efficiency a little. Idle time and high-speed time can be computed from `speed_samples` when the phone sends the whole trip |

Vehicle weight and road-load coefficients come in the EPA vehicle data the app sends.

`duration_s` and `heading_change_deg` are stored in two `trip_events` columns added by [`backend/db/002_event_details.sql`](../backend/db/002_event_details.sql), since `analytics/schema.sql` v1 doesn't have them.
