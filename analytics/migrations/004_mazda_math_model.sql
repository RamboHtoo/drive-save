-- v3 -> v4: additive event timing and detector coverage; preserve historical receipts.
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '120s';
SELECT pg_advisory_xact_lock(20261024, 4);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public'
    AND table_name='trips' AND column_name='model_result') THEN
    RAISE EXCEPTION 'Apply migration 003_fuel_model_receipts.sql first';
  END IF;
END $$;
ALTER TABLE public.trips ADD COLUMN IF NOT EXISTS events_complete boolean NOT NULL DEFAULT false;
ALTER TABLE public.trips ADD COLUMN IF NOT EXISTS detector_version text;
ALTER TABLE public.trip_events ADD COLUMN IF NOT EXISTS duration_s double precision;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.trips'::regclass AND conname='trips_math_model_demo_only') THEN
    ALTER TABLE public.trips ADD CONSTRAINT trips_math_model_demo_only
      CHECK (coalesce(model_result->>'estimate_kind','') <> 'experimental_math_model' OR is_demo);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.trips'::regclass AND conname='trips_detector_version_check') THEN
    ALTER TABLE public.trips ADD CONSTRAINT trips_detector_version_check
      CHECK (detector_version IS NULL OR length(trim(detector_version)) BETWEEN 1 AND 100);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='public.trip_events'::regclass AND conname='trip_events_duration_valid') THEN
    ALTER TABLE public.trip_events ADD CONSTRAINT trip_events_duration_valid
      CHECK (duration_s > 0 AND duration_s <= 120 AND duration_s < 'Infinity'::float8);
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
    'events_complete', t.events_complete, 'detector_version', t.detector_version,
    'quality_flags', t.quality_flags,
    'model_result', t.model_result,
    'scoring_config_id', sc.id, 'model_version', sc.model_version,
    'fuel_price_usd_per_gal', sc.fuel_price_usd_per_gal,
    'assumptions', coalesce(sc.assumptions, '[]'::jsonb),
    'events', coalesce((SELECT jsonb_agg(jsonb_build_object(
      'event_id', e.event_id, 'ts', e.ts, 'type', e.type, 'peak_g', e.peak_g,
      'cost_usd', e.cost_usd, 'detector_version', e.detector_version,
      'duration_s', e.duration_s, 'speed_before_mph', e.speed_before_mph, 'speed_after_mph', e.speed_after_mph
    ) ORDER BY e.ts, e.event_id) FROM public.trip_events e WHERE e.trip_id = t.id), '[]'::jsonb)
  )
  FROM public.trips t LEFT JOIN public.scoring_configs sc ON sc.id = t.scoring_config_id
  WHERE t.id = p_trip_id AND t.user_id = p_user_id;
$$;

INSERT INTO public.schema_versions(version) VALUES(4) ON CONFLICT DO NOTHING;
COMMIT;
SELECT max(version) AS schema_version FROM public.schema_versions;
