"""Compatibility import for the local showcase audit; implementation lives in backend."""
from services.league_demo import *  # noqa: F401,F403


def install(app):
    """Routes are now registered exactly once by backend/main.py."""
    return app
