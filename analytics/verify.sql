-- Read-only checks after applying schema.sql in Tiger Cloud.
SELECT version, applied_at FROM public.schema_versions ORDER BY version;

SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
ORDER BY table_name;

-- Expected: trip_events, speed_samples, trip_metrics.
SELECT hypertable_name
FROM timescaledb_information.hypertables
WHERE hypertable_schema = 'public'
ORDER BY hypertable_name;

-- Expected: daily_user_metrics, materialized_only = false.
SELECT view_name, materialized_only
FROM timescaledb_information.continuous_aggregates
WHERE view_schema = 'public';

-- Expected: one refresh policy, scheduled = true.
SELECT proc_name, schedule_interval, scheduled
FROM timescaledb_information.jobs
WHERE proc_name = 'policy_refresh_continuous_aggregate';

-- Some editors display only the last result. This combines the setup checks.
-- Expected: 4, 3, followed by true flags.
SELECT
  (SELECT max(version) FROM public.schema_versions) AS schema_version,
  (SELECT count(*) FROM timescaledb_information.hypertables
    WHERE hypertable_schema = 'public'
      AND hypertable_name IN ('trip_events', 'speed_samples', 'trip_metrics')) AS hypertables,
  EXISTS (SELECT 1 FROM timescaledb_information.continuous_aggregates
    WHERE view_schema = 'public' AND view_name = 'daily_user_metrics'
      AND NOT materialized_only) AS real_time_aggregate_enabled,
  EXISTS (SELECT 1 FROM timescaledb_information.jobs
    WHERE proc_name = 'policy_refresh_continuous_aggregate' AND scheduled) AS refresh_scheduled,
  to_regclass('public.leagues') IS NOT NULL AS leagues_ready,
  to_regprocedure('public.drive_save_leaderboard(uuid,timestamp with time zone,boolean)') IS NOT NULL AS individual_leaderboard_ready,
  EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public'
    AND table_name='trips' AND column_name='model_result') AS model_receipts_ready,
  EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public'
    AND table_name='trip_events' AND column_name='duration_s') AS event_duration_ready,
  EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public'
    AND table_name='trips' AND column_name='events_complete') AS detector_coverage_ready;
