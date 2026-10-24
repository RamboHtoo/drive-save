-- Event details the cost model uses that analytics/schema.sql v1 doesn't store.
-- Apply after schema.sql and queries.sql. Safe to rerun.
ALTER TABLE public.trip_events ADD COLUMN IF NOT EXISTS duration_s double precision;
ALTER TABLE public.trip_events ADD COLUMN IF NOT EXISTS heading_change_deg double precision;

SELECT 'trip_events now has duration_s and heading_change_deg' AS result;
