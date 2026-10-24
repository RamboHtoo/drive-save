"""Temporary in-memory storage so the skeleton behaves like the real API.

Everything here is lost when the server restarts. Stage 2 replaces this module
with Tiger Data tables (users, crews, crew_members, trips, ...).
"""

from dataclasses import dataclass, field
from datetime import datetime
from uuid import UUID

from pydantic import JsonValue

from models.trips import TripCreate


@dataclass
class UserRecord:
    user_id: UUID
    nickname: str
    token_hash: str
    vehicle: dict[str, JsonValue] | None = None  # as sent by the app


@dataclass
class CrewRecord:
    crew_id: UUID
    name: str
    join_code: str
    members: dict[UUID, datetime] = field(default_factory=dict)  # user_id -> joined_at
    is_demo: bool = False


@dataclass
class TripRecord:
    trip_id: UUID
    user_id: UUID
    trip: TripCreate
    uploaded_at: datetime
    # The car selected at upload time, so later car changes don't rewrite old receipts.
    vehicle: dict[str, JsonValue] | None = None


users: dict[UUID, UserRecord] = {}
users_by_token_hash: dict[str, UserRecord] = {}
crews: dict[UUID, CrewRecord] = {}
trips: dict[UUID, TripRecord] = {}
# (user_id, client_trip_id) -> trip_id, so a retried upload returns the same trip.
trip_ids_by_client_id: dict[tuple[UUID, UUID], UUID] = {}


def reset() -> None:
    """Clear all data. Used by tests."""
    users.clear()
    users_by_token_hash.clear()
    crews.clear()
    trips.clear()
    trip_ids_by_client_id.clear()
