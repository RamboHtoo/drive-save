"""Drive & Save API.

Run from this folder:  uvicorn main:app --reload --env-file .env
Interactive docs:      http://localhost:8000/docs
"""

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

import config
import db
from errors import register_error_handlers
from models.common import ErrorResponse, Health
from routes import crews, leaderboard, trips, users, vehicles


@asynccontextmanager
async def lifespan(_: FastAPI):
    await db.connect()
    yield
    await db.close()


app = FastAPI(
    title="Drive & Save API",
    version=config.APP_VERSION,
    description="Trips, receipts, crews and leaderboards for the Drive & Save iOS app.",
    lifespan=lifespan,
    # Document the shared error shape on every route.
    responses={401: {"model": ErrorResponse}, 403: {"model": ErrorResponse}, 404: {"model": ErrorResponse}, 422: {"model": ErrorResponse}},
)

app.add_middleware(CORSMiddleware, allow_origins=config.CORS_ORIGINS, allow_methods=["*"], allow_headers=["*"])
register_error_handlers(app)

app.include_router(users.router)
app.include_router(vehicles.router)
app.include_router(trips.router)
app.include_router(crews.router)
app.include_router(leaderboard.router)


@app.get("/health", response_model=Health, tags=["meta"])
async def health() -> Health:
    try:
        schema_version = await db.pool().fetchval("SELECT max(version) FROM schema_versions")
    except Exception:  # report the outage instead of failing the health check
        return Health(status="degraded", version=config.APP_VERSION, database="unavailable", schema_version=None)
    return Health(status="ok", version=config.APP_VERSION, database="ok", schema_version=schema_version)
