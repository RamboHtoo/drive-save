-- Drive Save schema v4. Run the entire file in Tiger Cloud SQL Editor.
-- Requires TimescaleDB (verified on your service as 2.31.0).
-- No passwords, demo data, or destructive statements are included.
BEGIN;

-- BEGIN EXTENSION CHECK
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb') THEN
    RAISE EXCEPTION 'TimescaleDB must be installed before running this script';
  END IF;
END $$;
-- END EXTENSION CHECK

DO $$
BEGIN
  IF to_regclass('public.crews') IS NOT NULL THEN
    RAISE EXCEPTION 'Existing v1 database: run analytics/migrations/002_individual_leagues.sql instead of schema.sql';
  END IF;
  IF to_regclass('public.trips') IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'trips' AND column_name = 'model_result'
  ) THEN
    RAISE EXCEPTION 'Existing v2 database: run analytics/migrations/003_fuel_model_receipts.sql instead of schema.sql';
  END IF;
  IF to_regclass('public.trips') IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='trips' AND column_name='events_complete'
  ) THEN
    RAISE EXCEPTION 'Existing v3 database: run analytics/migrations/004_mazda_math_model.sql';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.schema_versions (
  version integer PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nickname text NOT NULL CHECK (length(trim(nickname)) BETWEEN 1 AND 80),
  token_hash text NOT NULL UNIQUE,
  vehicle jsonb,
  mpg_city numeric CHECK (mpg_city > 0 AND mpg_city < 'Infinity'::numeric),
  mpg_hwy numeric CHECK (mpg_hwy > 0 AND mpg_hwy < 'Infinity'::numeric),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.leagues (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 100),
  join_code text NOT NULL UNIQUE,
  is_demo boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.league_members (
  user_id uuid PRIMARY KEY REFERENCES public.users(id),
  league_id uuid NOT NULL REFERENCES public.leagues(id),
  joined_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS league_members_league_idx ON public.league_members (league_id);

-- Create a NEW configuration when vehicle, price, model, or assumptions change.
-- Existing receipts reference their original configuration.
CREATE TABLE IF NOT EXISTS public.scoring_configs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  model_version text NOT NULL,
  vehicle_profile jsonb NOT NULL CHECK (jsonb_typeof(vehicle_profile) = 'object'),
  fuel_price_usd_per_gal numeric(12,6) NOT NULL
    CHECK (fuel_price_usd_per_gal >= 0 AND fuel_price_usd_per_gal < 'Infinity'::numeric),
  assumptions jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(assumptions) = 'array'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.keep_scoring_config_immutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Scoring configurations are immutable; insert a new configuration';
END $$;
DROP TRIGGER IF EXISTS scoring_configs_immutable ON public.scoring_configs;
CREATE TRIGGER scoring_configs_immutable
  BEFORE UPDATE OR DELETE ON public.scoring_configs
  FOR EACH ROW EXECUTE FUNCTION public.keep_scoring_config_immutable();

CREATE TABLE IF NOT EXISTS public.trips (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id),
  client_trip_id uuid NOT NULL,
  league_id uuid REFERENCES public.leagues(id), -- membership snapshot at acceptance
  started_at timestamptz NOT NULL,
  ended_at timestamptz NOT NULL,
  distance_mi numeric(14,6) NOT NULL
    CHECK (distance_mi > 0 AND distance_mi < 'Infinity'::numeric),
  avg_speed_mph double precision CHECK (avg_speed_mph >= 0 AND avg_speed_mph <= 120),
  source text NOT NULL DEFAULT 'recorded'
    CHECK (source IN ('recorded', 'replayed', 'synthetic')),
  is_demo boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'unscored'
    CHECK (status IN ('unscored', 'insufficient_data', 'scored')),
  scoring_config_id uuid REFERENCES public.scoring_configs(id),
  fuel_gal numeric(14,6) CHECK (fuel_gal >= 0 AND fuel_gal < 'Infinity'::numeric),
  avoidable_usd numeric(14,6) CHECK (avoidable_usd >= 0 AND avoidable_usd < 'Infinity'::numeric),
  baseline_slot smallint CHECK (baseline_slot BETWEEN 1 AND 3),
  quality_flags jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(quality_flags) = 'array'),
  model_result jsonb CONSTRAINT trips_model_result_object
    CHECK (model_result IS NULL OR jsonb_typeof(model_result) = 'object'),
  events_complete boolean NOT NULL DEFAULT false,
  detector_version text CHECK (detector_version IS NULL OR length(trim(detector_version)) BETWEEN 1 AND 100),
  accepted_seq bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
  received_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, client_trip_id),
  UNIQUE (user_id, scoring_config_id, is_demo, baseline_slot),
  UNIQUE (id, started_at),
  CHECK (ended_at > started_at),
  CHECK (source = 'recorded' OR is_demo),
  CHECK (
    (status = 'scored' AND scoring_config_id IS NOT NULL
      AND fuel_gal IS NOT NULL AND avoidable_usd IS NOT NULL)
    OR (status <> 'scored' AND fuel_gal IS NULL AND avoidable_usd IS NULL)
  ),
  CHECK (baseline_slot IS NULL OR (status = 'scored' AND distance_mi >= 1)),
  CONSTRAINT trips_math_model_demo_only CHECK (
    coalesce(model_result->>'estimate_kind', '') <> 'experimental_math_model' OR is_demo
  ),
  CONSTRAINT trips_reference_model_demo_only CHECK (
    coalesce(model_result->>'estimate_kind', '') <> 'reference_car_simulation' OR is_demo
  )
);
CREATE INDEX IF NOT EXISTS trips_user_time_idx ON public.trips (user_id, started_at DESC);
CREATE INDEX IF NOT EXISTS trips_league_time_idx ON public.trips (league_id, started_at DESC);

CREATE TABLE IF NOT EXISTS public.trip_events (
  ts timestamptz NOT NULL,
  event_id uuid NOT NULL,
  trip_id uuid NOT NULL REFERENCES public.trips(id),
  type text NOT NULL CHECK (type IN ('harsh_brake', 'rapid_accel', 'sharp_turn')),
  peak_g double precision NOT NULL CHECK (peak_g >= 0 AND peak_g < 'Infinity'::float8),
  speed_before_mph double precision CHECK (speed_before_mph BETWEEN 0 AND 120),
  speed_after_mph double precision CHECK (speed_after_mph BETWEEN 0 AND 120),
  detector_version text NOT NULL,
  duration_s double precision CONSTRAINT trip_events_duration_valid
    CHECK (duration_s > 0 AND duration_s <= 120 AND duration_s < 'Infinity'::float8),
  cost_usd numeric(14,6) CHECK (cost_usd >= 0 AND cost_usd < 'Infinity'::numeric),
  PRIMARY KEY (ts, event_id)
);
CREATE INDEX IF NOT EXISTS trip_events_trip_time_idx ON public.trip_events (trip_id, ts);

CREATE TABLE IF NOT EXISTS public.speed_samples (
  ts timestamptz NOT NULL,
  trip_id uuid NOT NULL REFERENCES public.trips(id),
  sample_seq integer NOT NULL CHECK (sample_seq >= 0),
  speed_mps double precision CHECK (speed_mps BETWEEN 0 AND 53.6448),
  speed_accuracy_mps double precision
    CHECK (speed_accuracy_mps >= 0 AND speed_accuracy_mps < 'Infinity'::float8),
  PRIMARY KEY (trip_id, ts, sample_seq)
);

-- Server-only analytics projection, inserted in the same transaction as scoring.
-- Trip timestamp FK prevents a second metrics row at a different timestamp.
CREATE TABLE IF NOT EXISTS public.trip_metrics (
  ts timestamptz NOT NULL, -- exact copy of trips.started_at
  trip_id uuid NOT NULL,
  user_id uuid NOT NULL REFERENCES public.users(id),
  league_id uuid REFERENCES public.leagues(id),
  scoring_config_id uuid NOT NULL REFERENCES public.scoring_configs(id),
  distance_mi numeric(14,6) NOT NULL
    CHECK (distance_mi > 0 AND distance_mi < 'Infinity'::numeric),
  fuel_gal numeric(14,6) NOT NULL CHECK (fuel_gal >= 0 AND fuel_gal < 'Infinity'::numeric),
  avoidable_usd numeric(14,6) NOT NULL CHECK (avoidable_usd >= 0 AND avoidable_usd < 'Infinity'::numeric),
  is_baseline boolean NOT NULL,
  is_demo boolean NOT NULL,
  PRIMARY KEY (trip_id, ts),
  FOREIGN KEY (trip_id, ts) REFERENCES public.trips(id, started_at)
);
CREATE INDEX IF NOT EXISTS trip_metrics_user_time_idx ON public.trip_metrics (user_id, ts DESC);
CREATE INDEX IF NOT EXISTS trip_metrics_league_time_idx ON public.trip_metrics (league_id, ts DESC);

-- Signed improvement compared with a baseline, not actual bank transfers.
CREATE TABLE IF NOT EXISTS public.savings_ledger (
  trip_id uuid PRIMARY KEY REFERENCES public.trips(id),
  user_id uuid NOT NULL REFERENCES public.users(id),
  amount_usd numeric(14,6) NOT NULL CHECK (abs(amount_usd) < 'Infinity'::numeric),
  kind text NOT NULL DEFAULT 'estimated' CHECK (kind = 'estimated'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.game_results (
  game_id uuid PRIMARY KEY,
  code text NOT NULL,
  finished_at timestamptz NOT NULL,
  results jsonb NOT NULL
);

-- BEGIN TIMESCALE SETUP
SELECT create_hypertable('public.trip_events', by_range('ts'), if_not_exists => true);
SELECT create_hypertable('public.speed_samples', by_range('ts'), if_not_exists => true);
SELECT create_hypertable('public.trip_metrics', by_range('ts'), if_not_exists => true);

-- Aggregate sums first; divide sums when querying, never average trip ratios.
CREATE MATERIALIZED VIEW IF NOT EXISTS public.daily_user_metrics
WITH (timescaledb.continuous) AS
SELECT
  time_bucket(INTERVAL '1 day', ts) AS day,
  user_id,
  league_id,
  scoring_config_id,
  is_baseline,
  is_demo,
  count(*) AS trip_count,
  sum(distance_mi) AS distance_mi,
  sum(fuel_gal) AS fuel_gal,
  sum(avoidable_usd) AS avoidable_usd
FROM public.trip_metrics
GROUP BY day, user_id, league_id, scoring_config_id, is_baseline, is_demo
WITH NO DATA;

ALTER MATERIALIZED VIEW public.daily_user_metrics
  SET (timescaledb.materialized_only = false);

SELECT add_continuous_aggregate_policy(
  'public.daily_user_metrics',
  start_offset => INTERVAL '30 days',
  end_offset => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 minute',
  if_not_exists => true
);
-- END TIMESCALE SETUP

INSERT INTO public.schema_versions (version) VALUES (4) ON CONFLICT DO NOTHING;
COMMIT;

-- Expected result: highest version 4 and a non-null applied_at.
SELECT version, applied_at FROM public.schema_versions ORDER BY version;
