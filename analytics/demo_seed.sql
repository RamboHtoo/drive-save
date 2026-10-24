-- Requires schema.sql and queries.sql. SYNTHETIC DATA, not actual trips or savings.
-- Two crews x four drivers x (three baseline trips + one later trip).
-- Fixed IDs make reruns safe. Existing fixture rows are not changed on rerun.
BEGIN;
SET LOCAL TIME ZONE 'UTC';

INSERT INTO public.crews (id, name, join_code, is_demo) VALUES
  ('d0000000-0000-4000-8000-000000000001', 'Demo East Halls', 'DEMO-EAST-V1', true),
  ('d0000000-0000-4000-8000-000000000002', 'Demo West Halls', 'DEMO-WEST-V1', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.users(id, nickname, token_hash, vehicle, mpg_city, mpg_hwy)
SELECT ('d1000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
  'Demo Driver ' || n,
  -- No login token is issued for fixture users.
  'fixture-disabled-' || gen_random_uuid()::text,
  '{"label":"Synthetic demo car"}'::jsonb, 30, 30
FROM generate_series(1, 8) AS n ON CONFLICT (id) DO NOTHING;

INSERT INTO public.crew_members(user_id, crew_id)
SELECT ('d1000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
  CASE WHEN n <= 4 THEN 'd0000000-0000-4000-8000-000000000001'::uuid
       ELSE 'd0000000-0000-4000-8000-000000000002'::uuid END
FROM generate_series(1, 8) AS n ON CONFLICT (user_id) DO NOTHING;

INSERT INTO public.scoring_configs(id, model_version, vehicle_profile,
  fuel_price_usd_per_gal, assumptions) VALUES (
  'd2000000-0000-4000-8000-000000000001', 'synthetic-fixture-v1',
  '{"label":"Synthetic demo car","purpose":"Database tests only"}', 3.50,
  '[{"key":"fixture_only","value":"Invented values for testing arithmetic, not a fuel model","unit":"description","source_url":null,"as_of":"2026-10-24"},
    {"key":"baseline_waste","value":0.10,"unit":"USD/mi","source_url":null,"as_of":"2026-10-24"}]'
) ON CONFLICT (id) DO NOTHING;

WITH fixture AS (
  SELECT n, k, md5('drive-save-demo-v1-trip-' || n || '-' || k)::uuid AS trip_id,
    ('d1000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid AS user_id,
    CASE WHEN n <= 4 THEN 'd0000000-0000-4000-8000-000000000001'::uuid
         ELSE 'd0000000-0000-4000-8000-000000000002'::uuid END AS crew_id,
    CASE WHEN k <= 3 THEN now() - INTERVAL '7 days' - (4-k) * INTERVAL '1 hour'
         ELSE now() - INTERVAL '40 minutes' END AS started_at,
    CASE WHEN k <= 3 THEN k::numeric ELSE 10::numeric END AS distance_mi,
    CASE WHEN k <= 3 THEN 0.10 * k
         WHEN n <= 4 THEN 0.80 ELSE 0.90 END AS avoidable_usd
  FROM generate_series(1, 8) AS n CROSS JOIN generate_series(1, 4) AS k
)
INSERT INTO public.trips(id, user_id, client_trip_id, crew_id, started_at, ended_at,
  distance_mi, avg_speed_mph, source, is_demo, status, scoring_config_id, fuel_gal,
  avoidable_usd, baseline_slot, quality_flags)
SELECT f.trip_id, f.user_id, f.trip_id, f.crew_id, f.started_at,
  f.started_at + INTERVAL '30 minutes', f.distance_mi, (f.distance_mi * 2)::float8,
  'synthetic', true, 'scored', 'd2000000-0000-4000-8000-000000000001'::uuid,
  f.distance_mi / 30, f.avoidable_usd,
  CASE WHEN f.k <= 3 THEN f.k::smallint END,
  '["synthetic_fixture","sparse_demo_speed_trace","not_model_validation"]'::jsonb
FROM fixture f ORDER BY f.k, f.n ON CONFLICT (id) DO NOTHING;

INSERT INTO public.trip_metrics(ts, trip_id, user_id, crew_id, scoring_config_id,
  distance_mi, fuel_gal, avoidable_usd, is_baseline, is_demo)
SELECT t.started_at, t.id, t.user_id, t.crew_id, t.scoring_config_id,
  t.distance_mi, t.fuel_gal, t.avoidable_usd, t.baseline_slot IS NOT NULL, t.is_demo
FROM public.trips t
WHERE t.scoring_config_id = 'd2000000-0000-4000-8000-000000000001'
  AND t.source = 'synthetic' AND t.is_demo
ON CONFLICT (trip_id, ts) DO NOTHING;

INSERT INTO public.trip_events(ts, event_id, trip_id, type, peak_g,
  speed_before_mph, speed_after_mph, detector_version)
SELECT t.started_at + n * INTERVAL '1 minute',
  md5(t.id::text || '-event-' || n)::uuid, t.id,
  CASE WHEN n = 1 THEN 'rapid_accel' ELSE 'harsh_brake' END,
  0.40, CASE WHEN n = 1 THEN 10 ELSE 30 END,
  CASE WHEN n = 1 THEN 30 ELSE 10 END, 'synthetic-fixture-v1'
FROM public.trips t CROSS JOIN generate_series(1, 2) AS n
WHERE t.scoring_config_id = 'd2000000-0000-4000-8000-000000000001'
  AND t.source = 'synthetic' AND t.is_demo
ON CONFLICT (ts, event_id) DO NOTHING;

INSERT INTO public.speed_samples(ts, trip_id, sample_seq, speed_mps, speed_accuracy_mps)
SELECT t.started_at + n * INTERVAL '1 second', t.id, n, 5 + n, 0.5
FROM public.trips t CROSS JOIN generate_series(0, 3) AS n
WHERE t.scoring_config_id = 'd2000000-0000-4000-8000-000000000001'
  AND t.source = 'synthetic' AND t.is_demo
ON CONFLICT (trip_id, ts, sample_seq) DO NOTHING;

COMMIT;

-- BEGIN DEMO REFRESH
-- Materialize CLOSED days only; today's rows are included by real-time queries.
-- Refresh is deliberately outside the fixture transaction.
CALL refresh_continuous_aggregate('public.daily_user_metrics',
  (date_trunc('day', now() AT TIME ZONE 'UTC') - INTERVAL '10 days') AT TIME ZONE 'UTC',
  date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC');
-- END DEMO REFRESH

-- Run in the creation week; for older fixtures pass their later-trip week instead.
SELECT rank, name, members, eligible_members,
  round(improvement_pct, 2) AS improvement_pct,
  round(est_savings_usd, 2) AS est_savings_usd, state, is_demo
FROM public.drive_save_crews(now(), true);
