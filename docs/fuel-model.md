# Mazda5 fuel-cost estimator

This offline Python library implements the Notion scenario model for the **2012
Mazda5 2.5L, five-speed automatic, FWD, regular gasoline**. It accepts phone-format
speed recordings and motion events. The repository contains no iOS application or
HTTP server; Person 1 records/detects, Person 2 authenticates/uploads, and this
library calculates the post-trip receipt.

Fuel costs and savings are experimental, not measured fuel flow. All results stay
in demo leagues, including real recordings (`source=recorded`, `is_demo=true`).
Phone-only testing cannot establish the accuracy of per-event savings.

## Run

Use Python 3.12:

```sh
python3.12 -m venv .venv
.venv/bin/python -m pip install -r requirements.lock
.venv/bin/python -m pip install --no-deps --no-build-isolation -e .
mkdir -p outputs
.venv/bin/python -m drive_save_model profile
.venv/bin/python -m drive_save_model example > outputs/mazda5-example-trip.json
.venv/bin/python -m drive_save_model estimate outputs/mazda5-example-trip.json > outputs/mazda5-receipt.json
.venv/bin/python -m drive_save_model demo > outputs/mazda5-four-player-demo.json
.venv/bin/python -m drive_save_model validate > outputs/mazda5-validation.json
.venv/bin/python -m pytest -q
.venv/bin/python tests/run_sql_tests.py --postgres-only --with-model
```

`validate` deliberately exits **2**: accuracy validation is incomplete. Formula
and software tests passing do not open this scientific release gate. The example
and four-player demo use synthetic data, not actual phone recordings. EPA speed
replays (`example --cycle hwfet`, `udds`, `us06`) have no IMU events and deliberately
fail competition eligibility until a complete detector recording exists.

## Sources and identity

- FuelEconomy.gov vehicle **31284** supplies identity and label MPG: 21 city, 28
  highway, 24 combined. Cached original response: `fueleconomy_31284.json`.
- EPA 2012 test vehicle **2ECL5XS1-001**, configuration **1**, supplies 157 hp,
  equivalent test weight 3750 lb, and target coefficients A=34.059 lbf,
  B=0.18979 lbf/mph, C=0.023476 lbf/mph². Cached rows retain original columns and
  test identifiers. Do not mix these with configuration 0 or the manual car.
- EPA HWFET, UDDS and US06 schedules are cached directly from EPA, with original
  units retained. They provide nominal speed inputs, not actual driven traces.
- `data/sources.json` records URLs, retrieval timestamps and SHA-256 hashes.
  `scripts/fetch_model_data.py` deliberately refreshes these public snapshots;
  scoring never calls external services. Refreshing data changes configuration
  identity and therefore the baseline. Review source changes before rollout.

Test weight is an operating-mass assumption, not the actual loaded car's weight.
The profile is for the US configuration. Other engines, markets, transmissions,
hybrids and electric vehicles are unsupported; there is no default-car fallback.

## Phone and backend contract

Keep recording throughout the trip, including stops. GPS supplies speed in m/s
and its reported uncertainty at roughly 1 Hz. Core Motion supplies event detection
at the app's higher sensor rate; remove gravity, align longitudinal/lateral axes,
and use a stable phone mount. Do not integrate the accelerometer to estimate speed.
The backend does not currently accept raw IMU streams or perform event detection.

```python
from drive_save_model import estimate_trip, reference_profile, scoring_config

# Create once per cohort and reuse. This is an example price, not a live quote.
config = scoring_config(3.50, price_as_of="2026-10-24")
result = estimate_trip(
    vehicle_profile=reference_profile(),
    speed_samples=samples,
    trip_metadata={
        "started_at": "2026-10-24T12:00:00Z",
        "ended_at": "2026-10-24T12:05:00Z",
        "distance_mi": measured_distance,
        "source": "recorded",
        "is_demo": True,
        "events_complete": True,
        "detector_version": "ios-motion-v1",
    },
    scoring_config=config,
    events=events,
)
```

Each speed sample contains `ts`, unique integer `sample_seq`, `speed_mps` and
`speed_accuracy_mps`. Invalid readings must be represented as missing, not zero.
Each event contains:

```json
{
  "event_id": "93c32cea-f250-4bb9-91be-0269d9ac5670",
  "ts": "2026-10-24T12:00:30Z",
  "duration_s": 3,
  "type": "harsh_brake",
  "peak_g": 0.34,
  "speed_before_mph": 34,
  "speed_after_mph": 12,
  "detector_version": "ios-motion-v1"
}
```

`ts` means **event start**, not peak time. Peak g is the gravity-corrected relevant
axis magnitude: longitudinal for acceleration/braking, lateral for turns. An
explicit `events=[]` means the detector ran successfully and found no events.
Only set `events_complete=true` when detection ran across the entire declared trip
and all events were uploaded. A sensor interruption or absent upload means false.
Version must be the same across the trip and its events. The backend checks these
fields; they cannot prove a malicious client is reporting honestly.

Trips last 3 seconds–2 hours, with at most 30,000 speed samples and 1,000 events.
Require valid boundary readings, 95% directly observed time coverage, maximum
3-second gaps, speed accuracy at most 2 m/s, speed at most 120 mph, and integrated
speed distance within 10% of reported distance. Reject changes above 1.5 g in the
resampled trace. Event duration is (0,120] seconds; peak magnitude is (0,2] g.
Event speed endpoints must agree with GPS within 2 m/s, and longitudinal average
acceleration cannot exceed the reported peak by more than 0.2 m/s². These are
engineering quality gates, not validated safety thresholds.

The backend supplies vehicle/configuration and all financial values. Clients do
not choose efficiency, cost, baseline slots, or arbitrary model versions. Source
labels must remain truthful even when `is_demo=true`.

## Calculations and interpretation

The version is `notion-mazda5-2012-auto-v1`:

- Road load: F(v)=A+Bv+Cv² after SI conversion. Steady fuel per metre is
  F(v)/(0.30×121.32 MJ/gal) + (0.25 gal/hour)/v. At zero speed this expression is
  not used; diagnostic idle fuel is explicitly 0.25 gal/hour.
- Braking compares the Notion early-coasting scenario at 0.05 g with cruising then
  braking. Extra distance is max(0,(v1²-v2²)/(2ac) − (v1+v2)t/2). Multiply by the
  steady fuel per metre at v1. Both decelerations assume zero fueling. This is an
  unobserved scenario assumption, not a phone measurement or guaranteed floor.
- Require recorded preceding history for extra_distance/v1 seconds, with speed
  within 2 m/s of v1. This makes the cruise approximation more plausible but does
  not establish that earlier braking was possible or that the driver used throttle.
- Acceleration uses the Notion energy and peak-power formulas, with an enrichment
  penalty beginning at 50% rated power and capped at 15%. These parameters are
  uncalibrated. Some harsh accelerations therefore get zero estimated fuel penalty.
- Sharp turns are coaching-only. A zero modeled dollar contribution does not mean
  that aggressive cornering has no real cost or is safe.
- High-speed cost compares each remaining segment with 65 mph. This is not a speed
  limit or recommended road speed. Split segments at event support boundaries and
  exclude all event/comparison seconds. Reject overlapping event support windows
  rather than count them twice. The resulting contribution excludes those windows.
- `avoidable_usd` sums braking, acceleration and the remaining high-speed amounts.
  The trip MPG budget (`fuel_gal`) is a separate approximate city/highway blend by
  average speed, using label MPG directly. Never add penalties to it or subtract
  penalties to manufacture a measured twin fuel total; `reference_fuel_gal` is null.
- Tire/brake wear, insurance and annual projections are excluded. The time
  difference is theoretical uninterrupted travel time, not observed time saved.

Store six decimal places for money. Round only for display; aggregate fractions
of cents before rounding. Missing financial results are null, never a clean zero.
Required receipt wording: **Estimated fuel savings; accuracy not yet validated.**
Never tell drivers to postpone necessary braking. Feedback belongs after the trip.

## Database and ranking

Schema v4 adds nullable `trip_events.duration_s` plus `trips.events_complete` and
`trips.detector_version`. Migration 004 preserves historical receipts and adds a
demo-only constraint for the experimental model. Apply it after migration 003.

```python
from drive_save_model.storage import score_stored_trip
async with conn.transaction():
    # Authenticate user; lock user row; check client_trip_id and changed retries.
    # Store trip, complete events and speed samples in this same transaction.
    receipt = await score_stored_trip(conn, authenticated_user_id, trip_id, config)
```

The adapter reads stored data, recalculates event costs, writes the receipt and
metrics atomically, and assigns eligible baseline slots. Person 2 implements
HTTP authentication, payload validation, immutable completed uploads, and rejection
of changed payloads under the same client_trip_id. The adapter opens no connections.

Rank percentage improvement in estimated waste per mile against the first three
eligible trips of at least one mile under the same immutable configuration. Keep
negative improvement and leave missing/zero baselines unranked. The new model has
a new configuration; historical model trips never enter its baseline. Frozen gas
price prevents price changes from looking like improved driving. Route/traffic
changes can still affect the comparison; this is not a validated safety ranking.

## Validation limits

`validate` compares full-trace diagnostic Willans predictions with configuration 1
HWFET (40.3 laboratory MPG) and US06 (24.2 laboratory MPG). These are **diagnostics**,
not validation of the separate label-MPG trip budget or the event penalties.
Actual dynamometer speed, gear, temperature and fuel-flow traces are unavailable.
FTP's 26.4 MPG is listed but not compared to a single UDDS replay because FTP uses
weighted cold/hot phases. No calibration or parameter fitting has been applied.

Real phone recordings are still needed to check sensor handling and repeatability.
Measured, synchronized fuel consumption plus separate evaluation trips are needed
before claiming accurate total fuel or accurate savings differences. Do not stage
harsh maneuvers on public roads to test detection; use synthetic traces instead.
