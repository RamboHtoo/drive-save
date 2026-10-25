"""Run fresh-install and v1 upgrade tests in temporary local PostgreSQL databases.

Usage: python3 tests/run_sql_tests.py --postgres-only
The explicit flag acknowledges that local PostgreSQL substitutes a live SQL view
for Timescale's continuous aggregate. Cloud refresh behavior is verified separately.
No real credentials or existing local databases are used.
"""

import argparse
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import sys


ROOT = Path(__file__).resolve().parents[1]


def command(args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout + result.stderr


def without_timescale(sql):
    for name in ("EXTENSION CHECK", "TIMESCALE SETUP", "DEMO REFRESH"):
        sql = re.sub(rf"-- BEGIN {name}.*?-- END {name}", "", sql, flags=re.S)
    return sql


def fingerprint(sql, renamed=False):
    """Compare data values before/after migration, accounting only for renames."""
    mappings = {"crews": "leagues", "crew_members": "league_members"} if renamed else {}
    results = []
    for old in ("users", "crews", "crew_members", "scoring_configs", "trips",
                "trip_events", "speed_samples", "trip_metrics", "savings_ledger", "game_results"):
        table = mappings.get(old, old)
        normalize = "replace(to_jsonb(t)::text, '\"league_id\":', '\"crew_id\":')::jsonb::text" if renamed else "to_jsonb(t)::text"
        results.append(sql(f"SELECT count(*), md5(coalesce(string_agg(row_data, '' ORDER BY row_data), '')) "
                           f"FROM (SELECT {normalize} AS row_data FROM public.{table} t) s;"))
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--postgres-only", action="store_true", required=True)
    parser.add_argument("--with-model", action="store_true", help="Also test Mazda5 math + asyncpg scoring end to end")
    parser.add_argument("--with-gps-backend", action="store_true", help="Test Swift GPS payload through both scoring/storage adapters (requires backend dependencies)")
    args = parser.parse_args()
    required = ("initdb", "pg_ctl", "psql", "createdb")
    binaries = {name: shutil.which(name) for name in required}
    if not all(binaries.values()):
        raise SystemExit("Install PostgreSQL tools: initdb, pg_ctl, psql, createdb")
    with tempfile.TemporaryDirectory(prefix="drive-save-tests-") as tmp:
        base = Path(tmp)
        started = False
        try:
            command([binaries["initdb"], "-D", str(base / "data"), "-A", "trust", "--no-locale", "-E", "UTF8"])
            command([binaries["pg_ctl"], "-D", str(base / "data"), "-l", str(base / "server.log"),
                     "-o", f"-h '' -k {base} -p 55439", "-w", "start"])
            started = True
            for mode in ("fresh", "upgrade"):
                command([binaries["createdb"], "-h", tmp, "-p", "55439", mode])

                def sql(text):
                    return command([binaries["psql"], "-h", tmp, "-p", "55439", "-d", mode,
                                    "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1"], input=text)

                folder = ROOT / ("analytics" if mode == "fresh" else "tests/fixtures/v1")
                original_schema = (folder / "schema.sql").read_text()
                sql(without_timescale(original_schema))
                sql("""CREATE FUNCTION public.time_bucket(interval,timestamptz)
                    RETURNS timestamptz LANGUAGE sql IMMUTABLE AS $$
                    SELECT date_bin($1,$2,'2000-01-03T00:00:00Z'::timestamptz) $$;""")
                rollup = original_schema.split("WITH (timescaledb.continuous) AS\n", 1)[1].split("\nWITH NO DATA;", 1)[0]
                sql("CREATE VIEW public.daily_user_metrics AS " + rollup + ";")
                if mode == "upgrade":
                    sql((folder / "queries.sql").read_text())
                    sql(without_timescale((folder / "demo_seed.sql").read_text()))
                    before = fingerprint(sql)
                    migration = (ROOT / "analytics/migrations/002_individual_leagues.sql").read_text()
                    # Rename semantics are tested with PostgreSQL's ordinary view.
                    migration = migration.replace("ALTER MATERIALIZED VIEW public.daily_user_metrics",
                                                  "ALTER VIEW public.daily_user_metrics")
                    sql(migration)
                    assert before == fingerprint(sql, renamed=True), "Migration changed original data"
                    sql(migration)
                    assert before == fingerprint(sql, renamed=True), "Migration rerun changed original data"
                    assert "t" in sql("SELECT to_regprocedure('public.drive_save_crews(timestamptz,boolean)') IS NULL;")
                    print("PASS: v1 data fingerprints preserved; migration rerun; collective ranking retired")
                    # v3 adds one nullable column; compare all previously stored values.
                    before_v3 = sql("SELECT md5(string_agg(to_jsonb(t)::text,'' ORDER BY id)) FROM public.trips t;")
                    model_migration = (ROOT / "analytics/migrations/003_fuel_model_receipts.sql").read_text()
                    sql(model_migration)
                    sql(model_migration)
                    after_v3 = sql("SELECT md5(string_agg((to_jsonb(t)-'model_result')::text,'' ORDER BY id)) FROM public.trips t;")
                    assert before_v3 == after_v3, "Model migration changed trip history"
                    print("PASS: v2 -> v3 receipts migration preserves history and reruns")
                before_v4 = sql("SELECT md5(coalesce(string_agg((to_jsonb(t)-'events_complete'-'detector_version')::text,'' ORDER BY id),'')) FROM public.trips t;")
                before_events = sql("SELECT md5(coalesce(string_agg((to_jsonb(t)-'duration_s')::text,'' ORDER BY ts,event_id),'')) FROM public.trip_events t;")
                migration4 = (ROOT / "analytics/migrations/004_mazda_math_model.sql").read_text()
                sql(migration4)
                sql(migration4)
                assert before_v4 == sql("SELECT md5(coalesce(string_agg((to_jsonb(t)-'events_complete'-'detector_version')::text,'' ORDER BY id),'')) FROM public.trips t;")
                assert before_events == sql("SELECT md5(coalesce(string_agg((to_jsonb(t)-'duration_s')::text,'' ORDER BY ts,event_id),'')) FROM public.trip_events t;")
                print("PASS: v4 migration and rerun preserve trips and events")
                sql(without_timescale((ROOT / "analytics/schema.sql").read_text()))
                sql((ROOT / "analytics/queries.sql").read_text())
                sql((ROOT / "analytics/queries.sql").read_text())
                seed = without_timescale((ROOT / "analytics/demo_seed.sql").read_text())
                print(sql(seed))
                sql(seed)
                print(sql((ROOT / "tests/schema_constraints.sql").read_text()))
                print(sql((ROOT / "tests/analytics_queries.sql").read_text()))
                print(sql((ROOT / "tests/model_receipts.sql").read_text()))
                if args.with_model:
                    print(command([sys.executable, str(ROOT / "tests/model_storage_integration.py"),
                                   "--socket", tmp, "--database", mode]))
                if args.with_gps_backend:
                    print(command([sys.executable, str(ROOT / "tests/gps_storage_integration.py"),
                                   "--socket", tmp, "--database", mode]))
                print(f"PASS: {mode} install, reruns, constraints and individual analytics")
        finally:
            if started:
                command([binaries["pg_ctl"], "-D", str(base / "data"), "-m", "fast", "-w", "stop"])
    print("LIMIT: Timescale continuous aggregate/policy behavior requires cloud verification.")


if __name__ == "__main__":
    main()
