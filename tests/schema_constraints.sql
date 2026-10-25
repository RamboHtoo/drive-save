-- Run against a disposable database containing schema.sql. Rolls back all fixtures.
BEGIN;
DO $$
DECLARE
  u uuid;
  cfg uuid;
  t uuid;
  client_id uuid := gen_random_uuid();
  start_time timestamptz := '2026-10-24T20:00:00Z';
BEGIN
  INSERT INTO public.users(nickname, token_hash)
    VALUES ('Schema Test Driver', gen_random_uuid()::text) RETURNING id INTO u;
  INSERT INTO public.scoring_configs(model_version, vehicle_profile, fuel_price_usd_per_gal)
    VALUES ('fixture-v1', '{}', 3.5) RETURNING id INTO cfg;
  INSERT INTO public.trips(user_id, client_trip_id, started_at, ended_at, distance_mi,
    status, scoring_config_id, fuel_gal, avoidable_usd, baseline_slot)
    VALUES (u, client_id, start_time, start_time + interval '10 minutes', 2,
      'scored', cfg, 0.1, 0, 1) RETURNING id INTO t;
  INSERT INTO public.trip_metrics(ts, trip_id, user_id, scoring_config_id,
    distance_mi, fuel_gal, avoidable_usd, is_baseline, is_demo)
    VALUES (start_time, t, u, cfg, 2, 0.1, 0, true, false);
  INSERT INTO public.trip_events(ts, event_id, trip_id, type, peak_g, detector_version)
    VALUES (start_time, gen_random_uuid(), t, 'harsh_brake', 0.4, 'fixture-v1');
  INSERT INTO public.speed_samples(ts, trip_id, sample_seq, speed_mps)
    VALUES (start_time, t, 0, NULL);
  INSERT INTO public.savings_ledger(trip_id, user_id, amount_usd) VALUES (t, u, -0.25);

  BEGIN
    INSERT INTO public.trips(user_id, client_trip_id, started_at, ended_at, distance_mi)
      VALUES (u, client_id, start_time, start_time + interval '10 minutes', 2);
    RAISE EXCEPTION 'Duplicate client trip was accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.trips(user_id, client_trip_id, started_at, ended_at, distance_mi)
      VALUES (u, gen_random_uuid(), start_time, start_time + interval '10 minutes', 0);
    RAISE EXCEPTION 'Zero distance was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.trips(user_id, client_trip_id, started_at, ended_at, distance_mi)
      VALUES (u, gen_random_uuid(), start_time, start_time + interval '10 minutes', 'NaN');
    RAISE EXCEPTION 'NaN distance was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.trips(user_id, client_trip_id, started_at, ended_at, distance_mi, status)
      VALUES (u, gen_random_uuid(), start_time, start_time + interval '10 minutes', 2, 'scored');
    RAISE EXCEPTION 'Scored trip without estimates was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.trips(user_id, client_trip_id, started_at, ended_at, distance_mi,
      status, scoring_config_id, fuel_gal, avoidable_usd, baseline_slot)
      VALUES (u, gen_random_uuid(), start_time, start_time + interval '10 minutes', 2,
        'scored', cfg, 0.1, 0.1, 1);
    RAISE EXCEPTION 'Duplicate baseline slot was accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.trips(user_id, client_trip_id, started_at, ended_at, distance_mi,
      status, scoring_config_id, fuel_gal, avoidable_usd, baseline_slot)
      VALUES (u, gen_random_uuid(), start_time, start_time + interval '10 minutes', 2,
        'scored', cfg, 0.1, 0.1, 4);
    RAISE EXCEPTION 'Fourth baseline slot was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.trip_metrics(ts, trip_id, user_id, scoring_config_id,
      distance_mi, fuel_gal, avoidable_usd, is_baseline, is_demo)
      VALUES (start_time + interval '1 second', t, u, cfg, 2, 0.1, 0, true, false);
    RAISE EXCEPTION 'Metrics at a different timestamp were accepted';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.trips(user_id, client_trip_id, started_at, ended_at, distance_mi, source)
      VALUES (u, gen_random_uuid(), start_time, start_time + interval '10 minutes', 2, 'synthetic');
    RAISE EXCEPTION 'Synthetic trip without demo label was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE public.scoring_configs SET model_version = 'changed' WHERE id = cfg;
    RAISE EXCEPTION 'Immutable config changed' USING ERRCODE = 'check_violation';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'Scoring configurations are immutable%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS: schema constraints, zero estimates, missing GPS, signed savings';
END $$;
ROLLBACK;
