-- Runtime role for the backend: reads and writes app data, can't change the schema.
-- Run once as tsdbadmin AFTER schema.sql, queries.sql and 002_event_details.sql.
-- Replace CHANGE_ME with a long random password (e.g. `openssl rand -hex 24`).
-- Never commit or paste the real password anywhere.
CREATE ROLE drivesave_app LOGIN PASSWORD 'CHANGE_ME';

GRANT CONNECT ON DATABASE tsdb TO drivesave_app;
GRANT USAGE ON SCHEMA public TO drivesave_app;

GRANT SELECT, INSERT, UPDATE ON
  public.users, public.crews, public.crew_members,
  public.trips, public.trip_events, public.speed_samples,
  public.trip_metrics, public.savings_ledger, public.game_results
TO drivesave_app;
GRANT SELECT, INSERT ON public.scoring_configs TO drivesave_app;
GRANT SELECT ON public.daily_user_metrics, public.schema_versions TO drivesave_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO drivesave_app;

SELECT 'drivesave_app role ready' AS result;
