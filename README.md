# drive-save
iOS app that turns driving habits into savings and friendly competition

Drivers compete individually within community leagues. Rankings use improvement
against each driver's first-three-trip baseline, with estimated savings displayed
alongside individual standings.

- [Product plan](docs/product-plan.md)
- [Database setup and migrations](docs/database-setup.md)
- [League API integration contract](docs/league-api.md)
- [Fuel estimator: run, integrate, and understand its validation limits](docs/fuel-model.md)

The data layer, analytics, and Python Mazda5 math estimator are implemented;
backend and iOS integration belong to their respective team owners. The estimator
is demo-only: independent laboratory validation and real-world accuracy are pending.

With Python 3.12 dependencies installed as described in the fuel-model guide:

```sh
.venv/bin/python -m drive_save_model demo
.venv/bin/python -m drive_save_model validate
.venv/bin/python -m pytest -q
```

The validation command exits 2 while its scientific release gate is unmet. It does
not mistake simulated cycle results for independent measured fuel accuracy.

Run the local PostgreSQL regression suite with installed PostgreSQL tools:

```sh
python3 tests/run_sql_tests.py --postgres-only
```

Add `--with-model` and use `.venv/bin/python` to test the Mazda5-math-to-asyncpg-to-
leaderboard flow as well.

This suite tests schema constraints, individual rankings, and migration data
preservation. It uses an ordinary live view in place of Timescale's continuous
aggregate; Timescale policy behavior requires cloud verification.
Files in `tests/fixtures/v1/` are historical migration-test snapshots, not deployment
scripts. Use the current files under `analytics/` for deployments.
