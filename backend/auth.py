"""Bearer-token auth.

POST /users issues a random token; only its SHA-256 hash is kept. Every
protected route depends on get_current_user. Auth0 (stretch goal) would
replace only this module.
"""

import hashlib
import secrets

from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

import store
from errors import ApiError

_bearer = HTTPBearer(auto_error=False)


def new_token() -> str:
    return secrets.token_urlsafe(32)


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


async def get_current_user(
    creds: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> store.UserRecord:
    if creds is None:
        raise ApiError(401, "unauthorized", "Missing bearer token")
    user = store.users_by_token_hash.get(hash_token(creds.credentials))
    if user is None:
        raise ApiError(401, "unauthorized", "Invalid token")
    return user
