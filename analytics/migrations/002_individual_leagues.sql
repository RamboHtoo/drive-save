-- Upgrade the existing v1 cloud database without deleting trip data.
-- Run the WHOLE file. New functions and renamed tables commit atomically.
-- Repeatable: a successful rerun keeps the same records and aggregates.
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '120s';
SELECT pg_advisory_xact_lock(hashtext('drive-save-schema'));

DO $migration$
BEGIN
  IF to_regclass('public.crews') IS NOT NULL
     AND to_regclass('public.leagues') IS NOT NULL THEN
    RAISE EXCEPTION 'Both crews and leagues exist; review the schema before migrating';
  ELSIF to_regclass('public.crews') IS NOT NULL THEN
    ALTER TABLE public.crews RENAME TO leagues;
    ALTER TABLE public.crew_members RENAME TO league_members;
    ALTER TABLE public.league_members RENAME COLUMN crew_id TO league_id;
    ALTER TABLE public.trips RENAME COLUMN crew_id TO league_id;
    ALTER TABLE public.trip_metrics RENAME COLUMN crew_id TO league_id;
    ALTER INDEX IF EXISTS public.crew_members_crew_idx RENAME TO league_members_league_idx;
    ALTER INDEX IF EXISTS public.trips_crew_time_idx RENAME TO trips_league_time_idx;
    ALTER INDEX IF EXISTS public.trip_metrics_crew_time_idx RENAME TO trip_metrics_league_time_idx;
  ELSIF to_regclass('public.leagues') IS NULL THEN
    RAISE EXCEPTION 'No v1 or v2 Drive Save schema found; use schema.sql for a new database';
  END IF;

  -- TimescaleDB 2.31 supports renaming a continuous aggregate column. Keep its
  -- materialized history and refresh policy, rather than dropping/rebuilding it.
  IF EXISTS (SELECT 1 FROM pg_attribute
    WHERE attrelid = to_regclass('public.daily_user_metrics')
      AND attname = 'crew_id' AND NOT attisdropped) THEN
    ALTER MATERIALIZED VIEW public.daily_user_metrics RENAME COLUMN crew_id TO league_id;
  END IF;
END $migration$;

-- Retire collective ranking and the former optional/global member query.
-- No CASCADE: an unexpected external dependency makes this transaction fail safely.
DROP FUNCTION IF EXISTS public.drive_save_crews(timestamptz, boolean);
DROP FUNCTION IF EXISTS public.drive_save_members(timestamptz, boolean, uuid);

DO $$
BEGIN
  IF to_regclass('public.leagues') IS NULL THEN
    RAISE EXCEPTION 'Install schema v2 or migration 002 before these analytics functions';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.drive_save_baseline(
  p_user_id uuid, p_scoring_config_id uuid, p_is_demo boolean
) RETURNS TABLE (baseline_trip_count bigint, baseline_usd_per_mile numeric, state text)
LANGUAGE sql STABLE AS $$
  SELECT count(*),
    CASE WHEN count(*) = 3 THEN sum(t.avoidable_usd) / sum(t.distance_mi) END,
    CASE WHEN count(*) < 3 THEN 'collecting_baseline'
         WHEN sum(t.avoidable_usd) = 0 THEN 'zero_baseline'
         ELSE 'ready' END
  FROM public.trips t
  WHERE t.user_id = p_user_id AND t.scoring_config_id = p_scoring_config_id
    AND t.is_demo = p_is_demo AND t.status = 'scored'
    AND t.baseline_slot IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION public.drive_save_leaderboard(
  p_league_id uuid, p_week_start timestamptz, p_is_demo boolean
) RETURNS TABLE (
  rank bigint, user_id uuid, nickname text, league_id uuid, scoring_config_id uuid,
  baseline_trip_count bigint, trip_count bigint, distance_mi numeric,
  avoidable_usd numeric, baseline_usd_per_mile numeric,
  weekly_usd_per_mile numeric, improvement_pct numeric,
  est_savings_usd numeric, state text, is_demo boolean
) LANGUAGE sql STABLE AS $$
  WITH bounds AS (
    SELECT date_trunc('week', p_week_start AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS start_at
  ), latest_config AS (
    SELECT DISTINCT ON (t.user_id) t.user_id, t.scoring_config_id
    FROM public.trips t
    WHERE t.is_demo = p_is_demo AND t.scoring_config_id IS NOT NULL
    ORDER BY t.user_id, t.accepted_seq DESC
  ), weekly AS (
    SELECT d.user_id, d.league_id, d.scoring_config_id,
      sum(d.trip_count)::bigint AS trip_count, sum(d.distance_mi) AS distance_mi,
      sum(d.avoidable_usd) AS avoidable_usd
    FROM public.daily_user_metrics d CROSS JOIN bounds b
    WHERE d.day >= b.start_at AND d.day < b.start_at + INTERVAL '168 hours'
      AND d.is_demo = p_is_demo AND NOT d.is_baseline
    GROUP BY d.user_id, d.league_id, d.scoring_config_id
  ), measured AS (
    SELECT u.id AS user_id, u.nickname, cm.league_id, lc.scoring_config_id,
      b.baseline_trip_count,
      coalesce(w.trip_count, 0)::bigint AS trip_count,
      coalesce(w.distance_mi, 0::numeric) AS distance_mi,
      coalesce(w.avoidable_usd, 0::numeric) AS avoidable_usd,
      b.baseline_usd_per_mile,
      w.avoidable_usd / nullif(w.distance_mi, 0) AS weekly_usd_per_mile,
      CASE WHEN b.state <> 'ready' THEN b.state
           WHEN coalesce(w.distance_mi, 0) = 0 THEN 'no_weekly_trips'
           ELSE 'ready' END AS state
    FROM public.league_members cm
    JOIN public.leagues c ON c.id = cm.league_id AND c.is_demo = p_is_demo
    JOIN public.users u ON u.id = cm.user_id
    LEFT JOIN latest_config lc ON lc.user_id = u.id
    CROSS JOIN LATERAL public.drive_save_baseline(u.id, lc.scoring_config_id, p_is_demo) b
    LEFT JOIN weekly w ON w.user_id = u.id AND w.league_id = cm.league_id
      AND w.scoring_config_id = lc.scoring_config_id
    WHERE cm.league_id = p_league_id
  ), calculated AS (
    SELECT m.*,
      CASE WHEN m.state = 'ready' THEN
        100 * (m.baseline_usd_per_mile - m.weekly_usd_per_mile)
          / nullif(m.baseline_usd_per_mile, 0) END AS improvement_pct,
      CASE WHEN m.state = 'ready' THEN
        m.baseline_usd_per_mile * m.distance_mi - m.avoidable_usd END AS est_savings_usd
    FROM measured m
  ), ranked AS (
    SELECT v.user_id, dense_rank() OVER (ORDER BY v.improvement_pct DESC) AS rank
    FROM calculated v WHERE v.state = 'ready'
  )
  SELECT r.rank, v.user_id, v.nickname, v.league_id, v.scoring_config_id,
    v.baseline_trip_count, v.trip_count, v.distance_mi, v.avoidable_usd,
    v.baseline_usd_per_mile, v.weekly_usd_per_mile, v.improvement_pct,
    v.est_savings_usd, v.state, p_is_demo
  FROM calculated v LEFT JOIN ranked r ON r.user_id = v.user_id
  ORDER BY r.rank NULLS LAST, v.nickname, v.user_id;
$$;

CREATE OR REPLACE FUNCTION public.drive_save_progress(
  p_user_id uuid, p_scoring_config_id uuid, p_is_demo boolean,
  p_start_day timestamptz, p_end_day timestamptz
) RETURNS TABLE (
  day timestamptz, trip_count bigint, distance_mi numeric, fuel_gal numeric,
  avoidable_usd numeric, usd_per_mile numeric
) LANGUAGE sql STABLE AS $$
  -- Daily buckets: callers pass midnight-UTC boundaries, end exclusive.
  -- Includes baseline trips for history; competition functions exclude them.
  SELECT d.day, sum(d.trip_count)::bigint, sum(d.distance_mi), sum(d.fuel_gal),
    sum(d.avoidable_usd), sum(d.avoidable_usd) / nullif(sum(d.distance_mi), 0)
  FROM public.daily_user_metrics d
  WHERE d.user_id = p_user_id AND d.scoring_config_id = p_scoring_config_id
    AND d.is_demo = p_is_demo AND d.day >= p_start_day AND d.day < p_end_day
  GROUP BY d.day ORDER BY d.day;
$$;

CREATE OR REPLACE FUNCTION public.drive_save_receipt(p_trip_id uuid, p_user_id uuid)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  -- Independent subqueries prevent event/sample joins from multiplying money.
  SELECT jsonb_build_object(
    'trip_id', t.id, 'status', t.status, 'started_at', t.started_at,
    'ended_at', t.ended_at, 'distance_mi', t.distance_mi,
    'fuel_gal', t.fuel_gal, 'avoidable_fuel_usd', t.avoidable_usd,
    'source', t.source, 'is_demo', t.is_demo, 'is_estimate', true,
    'quality_flags', t.quality_flags,
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

CREATE OR REPLACE FUNCTION public.drive_save_timeline(p_trip_id uuid, p_user_id uuid)
RETURNS TABLE (bucket timestamptz, type text, event_count bigint, peak_g double precision)
LANGUAGE sql STABLE AS $$
  SELECT time_bucket(INTERVAL '10 seconds', e.ts), e.type, count(*), max(e.peak_g)
  FROM public.trip_events e JOIN public.trips t ON t.id = e.trip_id
  WHERE t.id = p_trip_id AND t.user_id = p_user_id
  GROUP BY 1, e.type ORDER BY 1, e.type;
$$;

CREATE OR REPLACE FUNCTION public.drive_save_speed_trace(p_trip_id uuid, p_user_id uuid)
RETURNS TABLE (ts timestamptz, sample_seq integer, speed_mps double precision,
  speed_accuracy_mps double precision)
LANGUAGE sql STABLE AS $$
  SELECT s.ts, s.sample_seq, s.speed_mps, s.speed_accuracy_mps
  FROM public.speed_samples s JOIN public.trips t ON t.id = s.trip_id
  WHERE t.id = p_trip_id AND t.user_id = p_user_id ORDER BY s.ts, s.sample_seq;
$$;

CREATE OR REPLACE FUNCTION public.drive_save_quality(p_user_id uuid, p_is_demo boolean)
RETURNS TABLE (trip_id uuid, status text, valid_speed_samples bigint,
  metrics_rows bigint, metrics_match boolean, quality_flags jsonb)
LANGUAGE sql STABLE AS $$
  SELECT t.id, t.status,
    (SELECT count(*) FROM public.speed_samples s WHERE s.trip_id = t.id AND s.speed_mps IS NOT NULL),
    (SELECT count(*) FROM public.trip_metrics m WHERE m.trip_id = t.id),
    CASE WHEN t.status <> 'scored' THEN
      NOT EXISTS (SELECT 1 FROM public.trip_metrics m WHERE m.trip_id = t.id)
    ELSE EXISTS (SELECT 1 FROM public.trip_metrics m WHERE m.trip_id = t.id
      AND m.ts = t.started_at AND m.user_id = t.user_id
      AND m.league_id IS NOT DISTINCT FROM t.league_id
      AND m.scoring_config_id = t.scoring_config_id AND m.is_demo = t.is_demo
      AND m.is_baseline = (t.baseline_slot IS NOT NULL)
      AND m.distance_mi = t.distance_mi AND m.fuel_gal = t.fuel_gal
      AND m.avoidable_usd = t.avoidable_usd) END,
    t.quality_flags
  FROM public.trips t WHERE t.user_id = p_user_id AND t.is_demo = p_is_demo
  ORDER BY t.started_at;
$$;


INSERT INTO public.schema_versions(version) VALUES (2) ON CONFLICT DO NOTHING;
COMMIT;

SELECT max(version) AS schema_version,
  to_regclass('public.leagues') IS NOT NULL AS leagues_ready,
  to_regclass('public.crews') IS NULL AS old_crew_table_retired,
  to_regprocedure('public.drive_save_leaderboard(uuid,timestamp with time zone,boolean)') IS NOT NULL
    AS individual_leaderboard_ready
FROM public.schema_versions;
