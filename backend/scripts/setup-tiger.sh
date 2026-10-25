#!/usr/bin/env bash
# Backend setup on Tiger Cloud, run from the repo by someone who has the tsdbadmin password:
#   backend/scripts/setup-tiger.sh "postgres://tsdbadmin@HOST:PORT/tsdb?sslmode=require"
# Pass the service's connection string from Tiger Console without the password; the
# script asks for it at a hidden prompt. The data teammate installs and migrates the
# schema and analytics functions (docs/database-setup.md); this script only adds what
# the backend needs on top. It
#   1. checks Tiger is at the schema version in analytics/schema.sql, and stops without
#      changing anything if not
#   2. applies backend/db/002_event_details.sql (an event column the backend stores)
#   3. creates the drivesave_app role, or gives it a new password if it exists
#   4. checks drivesave_app can read the tables and call the analytics functions
#   5. writes its DATABASE_URL into backend/.env on the Vultr server
# No password is printed, and it is safe to rerun.
set -euo pipefail
cd "$(dirname "$0")/../.."

ADMIN_URL=${1:-}
admin_user=${ADMIN_URL#*://}
admin_user=${admin_user%%@*}
if [[ $ADMIN_URL != *://*@* ]]; then
  echo 'Usage: backend/scripts/setup-tiger.sh "postgres://tsdbadmin@HOST:PORT/tsdb?sslmode=require"' >&2
  exit 1
elif [[ $admin_user == *:* ]]; then
  echo "Leave the password out of the connection string; the script asks for it." >&2
  exit 1
fi
APP_URL="postgres://drivesave_app@${ADMIN_URL#*@}"  # same service, the app's role
SERVER=${SERVER:-root@45.32.7.47}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/drivesave}
SKIP_SERVER=${SKIP_SERVER:-}  # set to 1 to leave the server's .env alone

command -v psql > /dev/null || { echo "psql not found. Install it with: brew install libpq && brew link --force libpq" >&2; exit 1; }

if [[ -z "${ADMIN_PW:-}" ]]; then  # ADMIN_PW skips the prompt; use it only for the local test database
  read -rsp "$admin_user password: " ADMIN_PW
  echo
fi
APP_PW=$(openssl rand -hex 24)

run_psql() {  # run_psql URL PASSWORD [psql args...]
  local url=$1 password=$2
  shift 2
  PGPASSWORD="$password" psql "$url" -v ON_ERROR_STOP=1 -q "$@"
}
admin() { run_psql "$ADMIN_URL" "$ADMIN_PW" "$@"; }
apply() {  # apply FILE (- for stdin), without the "already exists, skipping" notices
  admin -c "SET client_min_messages = warning" -f "$1" > /dev/null
}

echo "1/5 Schema version"
expected=$(sed -n -E 's/.*schema_versions \(version\) VALUES \(([0-9]+)\).*/\1/p' analytics/schema.sql | sort -n | tail -1)
has_schema=$(admin -tAc "SELECT to_regclass('public.schema_versions') IS NOT NULL")
version=0
if [[ $has_schema == t ]]; then
  version=$(admin -tAc "SELECT coalesce(max(version), 0) FROM public.schema_versions")
fi
if [[ $version != "$expected" ]]; then
  echo "Tiger is at schema version $version, but this checkout is written for version $expected." >&2
  echo "Nothing was changed. The data teammate sets up and migrates the schema (docs/database-setup.md)." >&2
  exit 1
fi
echo "    version $version, matching analytics/schema.sql"

echo "2/5 Event column"
apply backend/db/002_event_details.sql
echo "    trip_events has heading_change_deg"

echo "3/5 drivesave_app role"
sed "s/CHANGE_ME/$APP_PW/" backend/db/app_role.sql | apply -
echo "    role ready with a new password"

echo "4/5 Check the role"
run_psql "$APP_URL" "$APP_PW" -tA > /dev/null <<'SQL'
SELECT max(version) FROM schema_versions;
SELECT count(*) FROM users;
SELECT count(*) FROM leagues;
SELECT count(*) FROM daily_user_metrics;
SELECT count(*) FROM drive_save_leaderboard(gen_random_uuid(), now(), false);
SELECT count(*) FROM drive_save_baseline(gen_random_uuid(), gen_random_uuid(), false);
SELECT count(*) FROM drive_save_progress(gen_random_uuid(), gen_random_uuid(), false, now() - interval '8 weeks', now());
SQL
echo "    drivesave_app can read the tables and call the analytics functions"

echo "5/5 Server"
if [[ -n "$SKIP_SERVER" ]]; then
  echo "    skipped (SKIP_SERVER is set)"
else
  printf '%s\n' "postgres://drivesave_app:$APP_PW@${ADMIN_URL#*@}" | ssh -i "$SSH_KEY" -o BatchMode=yes "$SERVER" '
    read -r url
    env=/root/drive-save/backend/.env
    if grep -q "^DATABASE_URL=" "$env"; then
      sed -i "s|^DATABASE_URL=.*|DATABASE_URL=$url|" "$env"
    else
      echo "DATABASE_URL=$url" >> "$env"
    fi
    chmod 600 "$env"'
  echo "    wrote DATABASE_URL into the server's backend/.env"
fi

echo "Done. The API connects to Tiger Cloud once the new version is deployed."
