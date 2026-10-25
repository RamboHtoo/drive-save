"""Runtime settings, read from environment variables (see .env.example)."""

import os

APP_VERSION = "0.1.0"

# Tiger Data (Postgres + Timescale) connection string. Required: the app won't start without it.
DATABASE_URL = os.getenv("DATABASE_URL", "")

# Protects admin-only endpoints such as the demo reset.
ADMIN_KEY = os.getenv("ADMIN_KEY", "")

# Comma-separated origins allowed by CORS. "*" is fine for the hackathon.
CORS_ORIGINS = [o.strip() for o in os.getenv("CORS_ORIGINS", "*").split(",") if o.strip()]
