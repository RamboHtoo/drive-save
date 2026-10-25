"""Connection pool for Tiger Data (Postgres + TimescaleDB)."""

import json

import asyncpg

import config

_pool: asyncpg.Pool | None = None


async def _init_connection(conn: asyncpg.Connection) -> None:
    # jsonb columns (vehicle data, assumptions) go in and out as Python objects.
    await conn.set_type_codec("jsonb", encoder=json.dumps, decoder=json.loads, schema="pg_catalog")


async def connect() -> None:
    global _pool
    if not config.DATABASE_URL:
        raise RuntimeError("DATABASE_URL is not set; see backend/.env.example")
    _pool = await asyncpg.create_pool(config.DATABASE_URL, min_size=1, max_size=5, init=_init_connection, command_timeout=15)


async def close() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None


def pool() -> asyncpg.Pool:
    if _pool is None:
        raise RuntimeError("Database pool is not connected")
    return _pool
