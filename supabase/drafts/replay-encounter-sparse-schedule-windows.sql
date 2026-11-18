DO $sparse_schedule_contract$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.publish_encounter_schedule_batch(uuid,uuid,jsonb)'::regprocedure
  ) INTO v_definition;

  IF pg_catalog.strpos(v_definition, 'schedule_variant_24_hour_coverage_incomplete') > 0
     OR pg_catalog.strpos(v_definition, 'schedule_special_event_24_hour_coverage_incomplete') > 0 THEN
    RAISE EXCEPTION 'sparse encounter schedules still require full-day coverage';
  END IF;

  IF pg_catalog.strpos(v_definition, 'NOT BETWEEN 0 AND 4') = 0
     OR pg_catalog.strpos(v_definition, 'NOT BETWEEN 1 AND 4') = 0 THEN
    RAISE EXCEPTION 'sparse encounter slot count bounds are missing';
  END IF;

  IF pg_catalog.strpos(v_definition, '''gym''') = 0
     OR pg_catalog.strpos(v_definition, '''restaurant''') = 0 THEN
    RAISE EXCEPTION 'publisher does not recognize canonical existing dynamic scene keys';
  END IF;
END;
$sparse_schedule_contract$;
