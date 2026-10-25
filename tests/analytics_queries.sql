-- Requires the demo fixture, run in its creation week. Every change rolls back.
BEGIN;
DO $$
DECLARE
  u uuid := 'e1000000-0000-4000-8000-000000000001';
  league uuid := 'e0000000-0000-4000-8000-000000000001';
  cfg uuid := 'e2000000-0000-4000-8000-000000000001';
  test_trip uuid;
  new_cfg uuid;
  receipt jsonb;
BEGIN
  IF (SELECT count(*) FROM public.trips WHERE scoring_config_id = cfg) <> 16
    THEN RAISE EXCEPTION 'Fixture must have exactly 16 trips even after rerun'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.drive_save_baseline(u, cfg, true)
    WHERE baseline_trip_count = 3 AND baseline_usd_per_mile = 0.10 AND state = 'ready')
    THEN RAISE EXCEPTION 'Baseline is incorrect'; END IF;
  IF (SELECT count(*) FROM public.drive_save_leaderboard(league, now(), true)
    WHERE state = 'ready' AND trip_count = 1) <> 4
    THEN RAISE EXCEPTION 'Baseline trips entered weekly competition'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.drive_save_leaderboard(league, now(), true)
    WHERE nickname = 'Demo Alex' AND rank = 1 AND improvement_pct = 20 AND est_savings_usd = 0.20)
    THEN RAISE EXCEPTION 'Alex individual arithmetic is incorrect'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.drive_save_leaderboard(league, now(), true)
    WHERE nickname = 'Demo Blair' AND rank = 2 AND improvement_pct = 10 AND est_savings_usd = 0.10)
    THEN RAISE EXCEPTION 'Blair individual arithmetic is incorrect'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.drive_save_leaderboard(league, now(), true)
    WHERE nickname = 'Demo Casey' AND rank = 3 AND improvement_pct = 0 AND est_savings_usd = 0)
    THEN RAISE EXCEPTION 'Zero improvement should still rank'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.drive_save_leaderboard(league, now(), true)
    WHERE nickname = 'Demo Drew' AND rank = 4 AND improvement_pct = -10 AND est_savings_usd = -0.10)
    THEN RAISE EXCEPTION 'Negative improvement should still rank'; END IF;
  IF EXISTS (SELECT 1 FROM public.drive_save_leaderboard(league, now(), false))
    THEN RAISE EXCEPTION 'Demo data leaked into real standings'; END IF;
  IF EXISTS (SELECT 1 FROM public.drive_save_leaderboard(NULL, now(), true))
    THEN RAISE EXCEPTION 'Null league must not return global rankings'; END IF;
  IF EXISTS (SELECT 1 FROM public.drive_save_quality(u, true) WHERE NOT metrics_match)
    THEN RAISE EXCEPTION 'Metrics do not match trips'; END IF;

  SELECT id INTO test_trip FROM public.trips WHERE user_id = u AND baseline_slot IS NULL;
  receipt := public.drive_save_receipt(test_trip, u);
  IF (receipt->>'avoidable_fuel_usd')::numeric <> 0.80
      OR jsonb_array_length(receipt->'events') <> 2
    THEN RAISE EXCEPTION 'Receipt totals/events are incorrect'; END IF;
  IF public.drive_save_receipt(test_trip, gen_random_uuid()) IS NOT NULL
    THEN RAISE EXCEPTION 'Receipt owner predicate failed'; END IF;
  IF (SELECT count(*) FROM public.drive_save_speed_trace(test_trip, u)) <> 4
    THEN RAISE EXCEPTION 'Speed trace is incomplete'; END IF;
  IF (SELECT sum(event_count) FROM public.drive_save_timeline(test_trip, u)) <> 2
    THEN RAISE EXCEPTION 'Timeline event count is incorrect'; END IF;
  IF (SELECT sum(trip_count) FROM public.drive_save_progress(u, cfg, true,
      (date_trunc('day', now() AT TIME ZONE 'UTC') - INTERVAL '10 days') AT TIME ZONE 'UTC',
      (date_trunc('day', now() AT TIME ZONE 'UTC') + INTERVAL '1 day') AT TIME ZONE 'UTC')) <> 4
    THEN RAISE EXCEPTION 'History should include baseline trips'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.drive_save_leaderboard(league, now() + INTERVAL '28 days', true)
    WHERE user_id = u AND state = 'no_weekly_trips' AND rank IS NULL)
    THEN RAISE EXCEPTION 'Empty week should be unranked'; END IF;

  -- Equal improvement shares a rank; savings do not break the tie.
  UPDATE public.trips SET avoidable_usd = 0.90 WHERE id = test_trip;
  UPDATE public.trip_metrics SET avoidable_usd = 0.90 WHERE trip_id = test_trip;
  IF (SELECT count(*) FROM public.drive_save_leaderboard(league, now(), true)
      WHERE rank = 1 AND improvement_pct = 10) <> 2
    THEN RAISE EXCEPTION 'Equal individual performance should share rank'; END IF;
  UPDATE public.trips SET avoidable_usd = 0.80 WHERE id = test_trip;
  UPDATE public.trip_metrics SET avoidable_usd = 0.80 WHERE trip_id = test_trip;

  -- League isolation and ranking without a four-member eligibility gate.
  INSERT INTO public.leagues(id,name,join_code,is_demo)
    VALUES ('e0000000-0000-4000-8000-000000000002', 'Test Other League', gen_random_uuid()::text, true);
  UPDATE public.league_members SET league_id = 'e0000000-0000-4000-8000-000000000002'
    WHERE league_id = league AND user_id <> u;
  IF (SELECT count(*) FROM public.drive_save_leaderboard(league, now(), true)) <> 1
    OR NOT EXISTS (SELECT 1 FROM public.drive_save_leaderboard(league, now(), true)
      WHERE user_id = u AND rank = 1)
    THEN RAISE EXCEPTION 'Single driver should remain ranked in their league'; END IF;
  IF EXISTS (SELECT 1 FROM public.drive_save_leaderboard(
      'e0000000-0000-4000-8000-000000000002', now(), true) WHERE trip_count <> 0 OR rank IS NOT NULL)
    THEN RAISE EXCEPTION 'Historical trips followed drivers into another league'; END IF;
  UPDATE public.league_members SET league_id = league
    WHERE league_id = 'e0000000-0000-4000-8000-000000000002';

  -- Raw baseline math must use distance-weighted totals, not average trip ratios.
  UPDATE public.trips SET avoidable_usd = 0.60 WHERE user_id = u AND baseline_slot = 3;
  IF NOT EXISTS (SELECT 1 FROM public.drive_save_baseline(u, cfg, true)
      WHERE baseline_usd_per_mile = 0.15)
    THEN RAISE EXCEPTION 'Baseline is not distance weighted'; END IF;
  UPDATE public.trips SET avoidable_usd = 0 WHERE user_id = u AND baseline_slot IS NOT NULL;
  IF NOT EXISTS (SELECT 1 FROM public.drive_save_leaderboard(league, now(), true)
      WHERE user_id = u AND state = 'zero_baseline' AND rank IS NULL AND improvement_pct IS NULL)
    THEN RAISE EXCEPTION 'Zero baseline should be unranked'; END IF;
  UPDATE public.trips SET avoidable_usd = 0.10 * distance_mi
    WHERE user_id = u AND baseline_slot IS NOT NULL;

  -- Editing fixture rows here is TEST ONLY; production baselines stay frozen.
  -- A costlier later trip must produce negative improvement rather than clipping.
  UPDATE public.trips SET avoidable_usd = 2 WHERE id = test_trip;
  UPDATE public.trip_metrics SET avoidable_usd = 2 WHERE trip_id = test_trip;
  -- Use a fresh raw-compatible view in local tests; on Timescale today's live tail
  -- is visible without refresh. Fixture verification should run during creation day.
  IF NOT EXISTS (SELECT 1 FROM public.drive_save_leaderboard(league, now(), true)
      WHERE user_id = u AND improvement_pct = -100 AND est_savings_usd = -1)
    THEN RAISE EXCEPTION 'Negative improvement was lost'; END IF;

  INSERT INTO public.scoring_configs(model_version, vehicle_profile, fuel_price_usd_per_gal)
    VALUES ('test-new-config', '{}', 3.5) RETURNING id INTO new_cfg;
  INSERT INTO public.trips(user_id, client_trip_id, started_at, ended_at,
    distance_mi, source, is_demo, status, scoring_config_id, fuel_gal, avoidable_usd)
    VALUES (u, gen_random_uuid(), now() - INTERVAL '5 minutes', now(),
      1, 'synthetic', true, 'scored', new_cfg, 0.04, 0.02);
  IF NOT EXISTS (SELECT 1 FROM public.drive_save_leaderboard(league, now(), true)
      WHERE user_id = u AND state = 'collecting_baseline' AND rank IS NULL)
    THEN RAISE EXCEPTION 'New configuration reused the old baseline'; END IF;
  RAISE NOTICE 'PASS: individual rankings, ties, league isolation, one-member league, fixture rerun, baseline weighting, receipts, configuration reset';
END $$;
ROLLBACK;
