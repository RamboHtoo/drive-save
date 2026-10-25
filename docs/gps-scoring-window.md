# GPS scoring windows

Implemented 2026-10-25 for the analytics work in
[Drive Save / Latest2](https://www.notion.so/40409f8ad9ef807c9226ca99b5c59183).
Model version: `vehicle-fuel-v2`. Window policy: `observed-gps-window-v1`.

The recorder's start/stop times describe the session. GPS observations describe
the interval that can actually be priced. The model preserves both. It no longer
requires an observation within one microsecond of each recording-button time.

## Rules

1. Keep `started_at` and `ended_at` unchanged. Use each location's measurement
   timestamp, never its callback-arrival time. Reject duplicate timestamps,
   duplicate/invalid sequence numbers, and observations outside the session.
   Sort otherwise valid observations by time; delivery order need not match it.
2. A valid observation has finite speed in `[0, 53.6448]` m/s and finite speed
   accuracy in `[0, 2]` m/s. Missing/negative/out-of-range values are unknown,
   never zero. These samples cannot anchor or extend the scored interval.
3. Score the **first valid observation through the last valid observation**.
   That interval must last at least 3 seconds. The original session must still
   last 3–7,200 seconds. Do not move samples, duplicate them at the edges, hold
   speed beyond the observations, or extrapolate missing distance or cost.
4. Each unobserved edge must be at most **3 seconds**. Every interior gap between
   valid observations must also be at most **3 seconds**. The 1-microsecond
   comparison slack on these *three-second limits* only absorbs floating-point
   error; it is no longer an endpoint-matching requirement.
5. Direct coverage must be at least **95% of the original session**:

   `sum(min(next_valid_time - valid_time, 1 second)) / session_duration`

   Both unobserved edges and the interpolated portion of larger interior gaps
   count against this limit. Trimming never changes the coverage denominator.
   For example, a 20-second session with two 1-second edge gaps fails at 90%,
   even though each edge individually passes the three-second limit.
6. Interpolate linearly only between valid readings. Preserve all observation
   knots along with the one-second calculation grid. Check the 1.5 g speed-change
   gate on both raw observation segments and the resulting grid. This prevents
   a fractional-second speed spike from disappearing during resampling.
7. Integrate distance over that observed interval and keep the existing 10%
   comparison to reported trip distance. Do not rescale the observations or the
   reported distance to manufacture agreement. A large disagreement remains
   `insufficient_data`; the report shows both distances for investigation.
8. Every event and its required comparison history must lie in the scored
   interval. An event outside it rejects the monetary result; it is never
   silently discarded. Braking's earlier-cruise context must start no earlier
   than the first valid GPS observation. Detector completeness still refers to
   the original session, with a matching trip/event detector version.

These numerical limits are conservative engineering policies inherited from the
existing model, extended to unobserved edges. They are not measured guarantees
about GPS behavior or validated fuel-estimation accuracy.

Apple defines `CLLocation.timestamp` as the time the location was determined,
and a negative `speedAccuracy` makes the associated speed invalid. This is why
the contract uses observation timestamps and preserves unknown speed readings.
Sources: [timestamp](https://developer.apple.com/documentation/corelocation/cllocation/timestamp?language=objc),
[speedAccuracy](https://developer.apple.com/documentation/corelocation/cllocation/speedaccuracy?changes=latest_minor).

## Receipts and aggregation

`model_details.trace` records the original duration, scored start/end in UTC and
session-relative seconds, scored duration, both missing edges, coverage, gap
size, integrated/reported miles, and the policy name. `gps_window_trimmed` marks
any receipt whose observed interval is shorter than its recording session.

Money covers only the observed interval. The server labels such a result
“Estimated fuel savings for GPS-covered portion only; accuracy not yet validated”
and adds a note identifying unpriced seconds. It does not present the omitted
portion as zero-cost driving. Failure still returns null financial amounts.

`model_details.scored_distance_mi` is the observed integral rounded to six decimal
places for storage. Both storage adapters use it for metrics and per-mile
comparisons; the backend savings ledger uses it too. A baseline trip needs at
least one reported mile and one scored mile. Original uploaded miles, timestamps,
events, and samples remain intact for history and idempotent retries. The receipt
API adds `scored_distance_mi`, `scoring_started_at`, `scoring_ended_at`,
`scoring_duration_seconds`, `monetary_scope`, and `quality_flags`; older receipt
fields are retained.

Version v2 changes configuration IDs and starts new baselines. Old receipts keep
their original version and totals. Deploy the model/backend changes together and
reapply `analytics/queries.sql`: its baseline and quality functions use scored
miles for new receipts and reported miles for historical receipts lacking the
new field. No table migration or historical backfill is required. This work was
verified locally; no production deployment or database change was performed.

## Verification performed

`tests/fixtures/ios/swift-async-replay.json` was generated by compiling the actual
`TripUploadBuilder`, `APIJSON`, and their data types from iOS commit
`99c07bad52a38137255d004e24993501223c3f9a`. The generator supplies synthetic
observations on macOS. **It is not a physical iPhone recording.** The fixture
retains `source=replayed` and `is_demo=true`; `provenance.json` records the source,
generator, and payload hashes. The production Swift sources are not modified.

| Check | Result |
| --- | --- |
| Session duration | 301 seconds |
| GPS interval | 0.625 through 300.625 seconds |
| Leading / trailing unobserved time | 0.625 / 0.375 seconds |
| Direct session coverage | 99.6678% |
| Observed distance | 4.701667 miles at stored precision |
| Original GPS validator on those exact bytes | `missing_boundary_speed` |
| New GPS validator | Accepted |
| Unmodified Swift upload through the model | `event_recording_incomplete`; no money |
| Explicit synthetic test variant with completion metadata | Scored; all three events retained |

The current Swift builder omits trip-level completeness/version metadata. The
positive contract test adds those fields **only to its known synthetic inputs**
to isolate the GPS change. The read-only verifier never repairs a user's payload.
`source=recorded` and `is_demo=false` are also preserved; the experimental model's
demo-only gate continues to apply.

- 67 model tests pass in the isolated GPS change, including 25 new
  GPS-window/Swift-fixture cases. The broader local suite, which also contains
  separate analytics verification work, passed 137 tests.
- Disposable PostgreSQL tests pass for fresh installation and v1-to-v4 upgrade.
  Both analytics and backend adapters consume the Swift fixture, preserve raw
  timestamps, expose coverage, maintain idempotent retries, exclude incomplete
  detector inputs, and use scored miles for baselines/metrics. The backend ledger
  gives no artificial savings when only reported distance changes. A reported
  one-mile trip with 0.983333 scored miles does not take a baseline slot.
- Existing formula, rejection, four-driver ranking, migration, and
  rollback tests pass. PostgreSQL tests use an ordinary aggregate view;
  Timescale continuous-aggregate scheduling was not exercised.

Reproduce from the repository root, with the model and backend dependencies installed:

```sh
.venv/bin/python scripts/generate_ios_gps_fixture.py  # Swift/macOS required
.venv/bin/python -m pytest -q
.venv/bin/python tests/run_sql_tests.py --postgres-only --with-model --with-gps-backend
.venv/bin/python scripts/verify_ios_payload.py tests/fixtures/ios/swift-async-replay.json
```

The last command deliberately exits 2: GPS is accepted, but the unmodified
Swift upload lacks detector metadata. The model success variant is exercised in
`tests/model/test_ios_payload.py` and `tests/gps_storage_integration.py`.

## Remaining physical-device check

Open a recorded driving trip in the iOS app, then **Advanced Settings → Export
API JSON**. Save the shared text as a `.json` file. That is the actual upload
payload, containing timestamps, speeds, accuracies, distance, and events; the
current export excludes coordinates and dollar inputs. The export action appears
only when the recording passes the iOS upload builder's checks. A walking test,
incomplete recording, or old recording may not offer it.

Run the unchanged export through:

```sh
.venv/bin/python scripts/verify_ios_payload.py /path/to/actual-trip.json --output /path/to/report.json
```

The default uses an explicitly labeled reference-car test configuration. To
reproduce the driver's pricing, supply `--config /path/to/backend-scoring-config.json`
containing the actual backend configuration and `vehicle_profile`. The report
hashes the input and separates GPS acceptance from overall model acceptance.

A real iPhone export was not available during this work, so physical-device
acceptance remains pending. Do not replace that check with the synthetic fixture
or assert completeness for a real recording without evidence from the recorder.
