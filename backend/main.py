"""Drive & Save API.

Run from this folder:  uvicorn main:app --reload --env-file .env
Interactive docs:      http://localhost:8000/docs
"""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

import config
from errors import register_error_handlers
from models.common import ErrorResponse, Health
from routes import crews, leaderboard, trips, users, vehicles

app = FastAPI(
    title="Drive & Save API",
    version=config.APP_VERSION,
    description="Trips, receipts, crews and leaderboards for the Drive & Save iOS app.",
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
    return Health(status="ok", version=config.APP_VERSION)
