BEGIN;
DO $$
DECLARE
  trip uuid;
  owner uuid;
  result jsonb;
BEGIN
  SELECT id,user_id INTO trip,owner FROM public.trips
    WHERE user_id='e1000000-0000-4000-8000-000000000001' LIMIT 1;
  result := public.drive_save_receipt(trip,owner);
  IF NOT (result ? 'model_result') OR result->'model_result' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'Legacy receipts must include a null model_result';
  END IF;
  UPDATE public.trips SET model_result='{"estimate_kind":"reference_car_simulation","reference_fuel_gal":0.2,"validation_status":"laboratory_validation_pending"}'
    WHERE id=trip;
  result := public.drive_save_receipt(trip,owner);
  IF result->'model_result'->>'validation_status' <> 'laboratory_validation_pending' THEN
    RAISE EXCEPTION 'Model details are missing from receipt';
  END IF;
  BEGIN
    UPDATE public.trips SET source='recorded',is_demo=false WHERE id=trip;
    RAISE EXCEPTION 'Reference model was allowed in real standings';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE public.trips SET model_result='[]' WHERE id=trip;
    RAISE EXCEPTION 'Nonobject model details were accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  UPDATE public.trips SET model_result='{"estimate_kind":"experimental_math_model"}' WHERE id=trip;
  BEGIN
    UPDATE public.trips SET source='recorded',is_demo=false WHERE id=trip;
    RAISE EXCEPTION 'Math model was allowed in real standings';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE public.trip_events SET duration_s=0 WHERE trip_id=trip;
    RAISE EXCEPTION 'Invalid event duration accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE public.trips SET detector_version='' WHERE id=trip;
    RAISE EXCEPTION 'Blank detector version accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  IF public.drive_save_receipt(trip,gen_random_uuid()) IS NOT NULL THEN
    RAISE EXCEPTION 'Receipt leaked to another user';
  END IF;
END $$;
ROLLBACK;
