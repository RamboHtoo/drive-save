-- Runtime role for the backend: reads and writes app data, can't change the schema.
-- Run as tsdbadmin AFTER schema.sql, queries.sql, 002_event_details.sql and 003_vehicle_catalog.sql.
-- Replace CHANGE_ME with a long random password (e.g. `openssl rand -hex 24`).
-- Safe to rerun: rerunning sets a new password and reapplies the grants.
-- Never commit or paste the real password anywhere.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'drivesave_app') THEN
    CREATE ROLE drivesave_app LOGIN;
  END IF;
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO drivesave_app', current_database());
END $$;
ALTER ROLE drivesave_app WITH LOGIN PASSWORD 'CHANGE_ME';

GRANT USAGE ON SCHEMA public TO drivesave_app;
GRANT SELECT, INSERT, UPDATE ON
  public.users, public.leagues, public.league_members,
  public.trips, public.trip_events, public.speed_samples,
  public.trip_metrics, public.savings_ledger, public.game_results
TO drivesave_app;
GRANT SELECT, INSERT ON public.scoring_configs TO drivesave_app;
GRANT SELECT ON public.daily_user_metrics, public.schema_versions TO drivesave_app;
-- The vehicle list is read-only for the app; scripts/load_vehicles.py loads it as tsdbadmin.
GRANT SELECT ON public.vehicle_models, public.epa_test_cars, public.epa_test_car_files TO drivesave_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO drivesave_app;

SELECT 'drivesave_app role ready' AS result;
