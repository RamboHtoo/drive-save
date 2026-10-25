"""Loads the EPA Test Car List into the database: every test row, and the car picker
built from it with each car's fuel model parameters (docs/vehicle-catalog.md).

    python scripts/load_vehicles.py postgresql://postgres:test@localhost:55432/postgres
    PGPASSWORD=... python scripts/load_vehicles.py "postgres://tsdbadmin@HOST:PORT/tsdb?sslmode=require"

Needs the backend's dev requirements (openpyxl reads the Excel files) and the tables
from backend/db/003_vehicle_catalog.sql. It replaces any earlier load in one
transaction, so the API never sees a half-loaded catalog. --if-changed skips the load
when these files were already loaded with the current catalog version.
"""

import argparse
import asyncio
import json
import os
import sys
import time
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(BACKEND), str(BACKEND.parent)]  # services/, and the fuel model in drive_save_model/

import asyncpg  # noqa: E402

from services import epa_dataset, vehicle_catalog  # noqa: E402

DEFAULT_FOLDER = BACKEND.parent / "vehicle"
FILE_COLUMNS = ["file_name", "sha256", "model_year", "row_count", "skipped"]
ROW_COLUMNS = ["source_file", "source_row", "make", "model", *(name for name, _, _ in epa_dataset.COLUMNS), "unmapped"]
JSON_COLUMNS = {"unmapped", "parameters", "flags", "fit_error", "vehicle_profile", "variants"}


def _record(item: dict, columns: list[str]) -> tuple:
    return tuple(
        json.dumps(item[column], allow_nan=False) if column in JSON_COLUMNS and item[column] is not None else item[column] for column in columns
    )


async def _already_loaded(conn: asyncpg.Connection, files: list[epa_dataset.SourceFile]) -> bool:
    loaded = {(r["file_name"], r["sha256"]) for r in await conn.fetch("SELECT file_name, sha256 FROM public.epa_test_car_files")}
    versions = {r["catalog_version"] for r in await conn.fetch("SELECT DISTINCT catalog_version FROM public.vehicle_models")}
    return loaded == {(f.name, f.sha256) for f in files} and versions == {vehicle_catalog.CATALOG_VERSION}


async def load(url: str, folder: Path, if_changed: bool) -> None:
    started = time.monotonic()
    files = epa_dataset.read_folder(folder)
    conn = await asyncpg.connect(url)
    try:
        if if_changed and await _already_loaded(conn, files):
            print(f"Vehicle catalog already loaded from these {len(files)} files")
            return
        rows = [row for f in files for row in f.rows]
        entries = vehicle_catalog.build(rows)
        model_columns = list(entries[0]) if entries else []
        async with conn.transaction():
            await conn.execute("TRUNCATE public.vehicle_models, public.epa_test_cars, public.epa_test_car_files")
            await conn.copy_records_to_table(
                "epa_test_car_files",
                schema_name="public",
                columns=FILE_COLUMNS,
                records=[(f.name, f.sha256, f.model_year, len(f.rows), f.skipped) for f in files],
            )
            await conn.copy_records_to_table("epa_test_cars", schema_name="public", columns=ROW_COLUMNS, records=[_record(r, ROW_COLUMNS) for r in rows])
            await conn.copy_records_to_table("vehicle_models", schema_name="public", columns=model_columns, records=[_record(e, model_columns) for e in entries])
    finally:
        await conn.close()

    for f in files:
        print(f"  {f.name}: {f'skipped ({f.skipped})' if f.skipped else f'{len(f.rows)} rows, model year {f.model_year}'}")
    supported = sum(e["supported"] for e in entries)
    print(
        f"Loaded {len(rows)} test rows and {len(entries)} vehicles ({len({e['make'] for e in entries})} brands); "
        f"{supported} have fuel model parameters. {time.monotonic() - started:.0f} s"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("database_url", nargs="?", default=os.getenv("DATABASE_URL"), help="defaults to $DATABASE_URL; the password can come from $PGPASSWORD")
    parser.add_argument("--folder", type=Path, default=DEFAULT_FOLDER, help=f"EPA Test Car List files (default: {DEFAULT_FOLDER})")
    parser.add_argument("--if-changed", action="store_true", help="skip when these files are already loaded")
    args = parser.parse_args()
    if not args.database_url:
        parser.error("pass a database URL or set DATABASE_URL")
    if not args.folder.is_dir():
        parser.error(f"no folder {args.folder}")
    try:
        asyncio.run(load(args.database_url, args.folder, args.if_changed))
    except asyncpg.UndefinedTableError:
        print("The catalog tables are missing: apply backend/db/003_vehicle_catalog.sql first", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
