"""Bearer-token auth.

POST /users issues a random token; only its SHA-256 hash is stored. Every
protected route depends on get_current_user. Auth0 (stretch goal) would
replace only this module.
"""

import hashlib
import secrets

from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

import repo
from errors import ApiError

_bearer = HTTPBearer(auto_error=False)


def new_token() -> str:
    return secrets.token_urlsafe(32)


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


async def get_current_user(creds: HTTPAuthorizationCredentials | None = Depends(_bearer)) -> repo.User:
    if creds is None:
        raise ApiError(401, "unauthorized", "Missing bearer token")
    user = await repo.user_by_token_hash(hash_token(creds.credentials))
    if user is None:
        raise ApiError(401, "unauthorized", "Invalid token")
    return user
