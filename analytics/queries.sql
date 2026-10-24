-- Install these SQL analytics functions AFTER schema.sql.
-- Person 2 calls them with asyncpg parameters, e.g.:
-- SELECT * FROM drive_save_crews($1::timestamptz, $2::boolean);
-- The API must authorize user/crew access before calling these functions.
BEGIN;

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

CREATE OR REPLACE FUNCTION public.drive_save_members(
  p_week_start timestamptz, p_is_demo boolean, p_crew_id uuid DEFAULT NULL
) RETURNS TABLE (
  rank bigint, user_id uuid, nickname text, crew_id uuid, scoring_config_id uuid,
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
    SELECT d.user_id, d.crew_id, d.scoring_config_id,
      sum(d.trip_count)::bigint AS trip_count, sum(d.distance_mi) AS distance_mi,
      sum(d.avoidable_usd) AS avoidable_usd
    FROM public.daily_user_metrics d CROSS JOIN bounds b
    WHERE d.day >= b.start_at AND d.day < b.start_at + INTERVAL '168 hours'
      AND d.is_demo = p_is_demo AND NOT d.is_baseline
    GROUP BY d.user_id, d.crew_id, d.scoring_config_id
  ), measured AS (
    SELECT u.id AS user_id, u.nickname, cm.crew_id, lc.scoring_config_id,
      b.baseline_trip_count,
      coalesce(w.trip_count, 0)::bigint AS trip_count,
      coalesce(w.distance_mi, 0::numeric) AS distance_mi,
      coalesce(w.avoidable_usd, 0::numeric) AS avoidable_usd,
      b.baseline_usd_per_mile,
      w.avoidable_usd / nullif(w.distance_mi, 0) AS weekly_usd_per_mile,
      CASE WHEN b.state <> 'ready' THEN b.state
           WHEN coalesce(w.distance_mi, 0) = 0 THEN 'no_weekly_trips'
           ELSE 'ready' END AS state
    FROM public.crew_members cm
    JOIN public.crews c ON c.id = cm.crew_id AND c.is_demo = p_is_demo
    JOIN public.users u ON u.id = cm.user_id
    LEFT JOIN latest_config lc ON lc.user_id = u.id
    CROSS JOIN LATERAL public.drive_save_baseline(u.id, lc.scoring_config_id, p_is_demo) b
    LEFT JOIN weekly w ON w.user_id = u.id AND w.crew_id = cm.crew_id
      AND w.scoring_config_id = lc.scoring_config_id
    WHERE p_crew_id IS NULL OR cm.crew_id = p_crew_id
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
  SELECT r.rank, v.user_id, v.nickname, v.crew_id, v.scoring_config_id,
    v.baseline_trip_count, v.trip_count, v.distance_mi, v.avoidable_usd,
    v.baseline_usd_per_mile, v.weekly_usd_per_mile, v.improvement_pct,
    v.est_savings_usd, v.state, p_is_demo
  FROM calculated v LEFT JOIN ranked r ON r.user_id = v.user_id
  ORDER BY r.rank NULLS LAST, v.nickname, v.user_id;
$$;

CREATE OR REPLACE FUNCTION public.drive_save_crews(
  p_week_start timestamptz, p_is_demo boolean
) RETURNS TABLE (
  rank bigint, crew_id uuid, name text, members bigint, eligible_members bigint,
  improvement_pct numeric, est_savings_usd numeric, state text, is_demo boolean
) LANGUAGE sql STABLE AS $$
  WITH member_results AS (
    SELECT * FROM public.drive_save_members(p_week_start, p_is_demo)
  ), totals AS (
    SELECT c.id AS crew_id, c.name,
      count(m.user_id) AS members,
      count(m.user_id) FILTER (WHERE m.state = 'ready') AS eligible_members,
      avg(m.improvement_pct) FILTER (WHERE m.state = 'ready') AS improvement_pct,
      sum(m.est_savings_usd) FILTER (WHERE m.state = 'ready') AS est_savings_usd
    FROM public.crews c LEFT JOIN member_results m ON m.crew_id = c.id
    WHERE c.is_demo = p_is_demo GROUP BY c.id, c.name
  ), states AS (
    SELECT t.*, CASE WHEN t.members < 4 THEN 'needs_four_members'
      WHEN t.eligible_members = 0 THEN 'no_eligible_members' ELSE 'ready' END AS state
    FROM totals t
  ), ranked AS (
    SELECT s.crew_id, dense_rank() OVER (ORDER BY s.improvement_pct DESC) AS rank
    FROM states s WHERE s.state = 'ready'
  )
  SELECT r.rank, s.crew_id, s.name, s.members, s.eligible_members,
    s.improvement_pct, s.est_savings_usd, s.state, p_is_demo
  FROM states s LEFT JOIN ranked r ON r.crew_id = s.crew_id
  ORDER BY r.rank NULLS LAST, s.name, s.crew_id;
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
      AND m.crew_id IS NOT DISTINCT FROM t.crew_id
      AND m.scoring_config_id = t.scoring_config_id AND m.is_demo = t.is_demo
      AND m.is_baseline = (t.baseline_slot IS NOT NULL)
      AND m.distance_mi = t.distance_mi AND m.fuel_gal = t.fuel_gal
      AND m.avoidable_usd = t.avoidable_usd) END,
    t.quality_flags
  FROM public.trips t WHERE t.user_id = p_user_id AND t.is_demo = p_is_demo
  ORDER BY t.started_at;
$$;

COMMIT;
SELECT 'Drive Save analytics functions installed' AS result;
