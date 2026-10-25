"""Tests run against a real TimescaleDB with the shared schema.

Start one with backend/scripts/test-db.sh, or point TEST_DATABASE_URL at another
throwaway database. Every table is emptied before each test.
"""

import asyncio
import os

import asyncpg
import pytest

TEST_DATABASE_URL = os.environ.get("TEST_DATABASE_URL", "postgresql://postgres:test@localhost:55432/postgres")
os.environ["DATABASE_URL"] = TEST_DATABASE_URL  # config reads it when the app is imported

_TABLES = "users, leagues, league_members, scoring_configs, trips, trip_events, speed_samples, trip_metrics, savings_ledger, game_results"


async def _query(sql: str, *args):
    conn = await asyncpg.connect(TEST_DATABASE_URL)
    try:
        return await conn.fetch(sql, *args)
    finally:
        await conn.close()


def query(sql: str, *args):
    """Runs SQL against the test database from a test (outside the app's event loop)."""
    return asyncio.run(_query(sql, *args))


def pytest_sessionstart(session):
    try:
        query("SELECT 1 FROM schema_versions")
    except Exception as exc:
        pytest.exit(f"Test database not ready ({exc}). Run backend/scripts/test-db.sh first.", returncode=2)


@pytest.fixture(autouse=True)
def empty_tables():
    query(f"TRUNCATE {_TABLES} CASCADE")
    yield
