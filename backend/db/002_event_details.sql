-- The sharp-turn angle the cost model uses. The shared schema (version 4) has duration_s
-- but no column for this. Apply after the shared schema. Safe to rerun.
ALTER TABLE public.trip_events ADD COLUMN IF NOT EXISTS heading_change_deg double precision;

SELECT 'trip_events has heading_change_deg' AS result;
