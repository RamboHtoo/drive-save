-- v2 -> v3: preserve all history; add reference-model details to trip receipts.
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '120s';
SELECT pg_advisory_xact_lock(20261024, 3);
DO $$
BEGIN
  IF to_regclass('public.leagues') IS NULL THEN
    RAISE EXCEPTION 'Apply migration 002_individual_leagues.sql first';
  END IF;
END $$;
ALTER TABLE public.trips ADD COLUMN IF NOT EXISTS model_result jsonb;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = 'public.trips'::regclass AND conname = 'trips_model_result_object') THEN
    ALTER TABLE public.trips ADD CONSTRAINT trips_model_result_object
      CHECK (model_result IS NULL OR jsonb_typeof(model_result) = 'object');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = 'public.trips'::regclass AND conname = 'trips_reference_model_demo_only') THEN
    ALTER TABLE public.trips ADD CONSTRAINT trips_reference_model_demo_only
      CHECK (coalesce(model_result->>'estimate_kind', '') <> 'reference_car_simulation' OR is_demo);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.drive_save_receipt(p_trip_id uuid, p_user_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  -- Independent subqueries prevent event/sample joins from multiplying money.
  SELECT jsonb_build_object(
    'trip_id', t.id, 'status', t.status, 'started_at', t.started_at,
    'ended_at', t.ended_at, 'distance_mi', t.distance_mi,
    'fuel_gal', t.fuel_gal, 'avoidable_fuel_usd', t.avoidable_usd,
    'source', t.source, 'is_demo', t.is_demo, 'is_estimate', true,
    'quality_flags', t.quality_flags,
    'model_result', t.model_result,
    'scoring_config_id', sc.id, 'model_version', sc.model_version,
    'fuel_price_usd_per_gal', sc.fuel_price_usd_per_gal,
    'assumptions', coalesce(sc.assumptions, '[]'::jsonb),
    'events', coalesce((SELECT jsonb_agg(jsonb_build_object(
      'event_id', e.event_id, 'ts', e.ts, 'type', e.type, 'peak_g', e.peak_g,
      'cost_usd', e.cost_usd, 'detector_version', e.detector_version
    ) ORDER BY e.ts, e.event_id) FROM public.trip_events e WHERE e.trip_id = t.id), '[]'::jsonb)
  )
  FROM public.trips t LEFT JOIN public.scoring_configs sc ON sc.id = t.scoring_config_id
  WHERE t.id = p_trip_id AND t.user_id = p_user_id;
$$;

INSERT INTO public.schema_versions(version) VALUES (3) ON CONFLICT DO NOTHING;
COMMIT;
SELECT max(version) AS schema_version FROM public.schema_versions;
