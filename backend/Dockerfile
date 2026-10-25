# API image. Built from the repo root (see docker-compose.yml) so that the
# data teammate's fuel model (drive_save_model/) can be copied in.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

COPY backend/requirements.txt .
RUN pip install -r requirements.txt

COPY backend/ .
COPY drive_save_model/ ./drive_save_model/

RUN useradd --create-home --uid 10001 app
USER app

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"

# Exactly one worker: live game rooms are kept in memory.
# --proxy-headers trusts Caddy's X-Forwarded-* headers (client IP, https scheme).
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--proxy-headers", "--forwarded-allow-ips", "*"]
