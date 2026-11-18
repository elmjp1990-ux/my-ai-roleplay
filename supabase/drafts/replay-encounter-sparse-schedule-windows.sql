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

  SELECT pg_catalog.pg_get_functiondef(
    'public.resolve_encounter_character_schedule(uuid,uuid,text,timestamptz)'::regprocedure
  ) INTO v_definition;

  IF pg_catalog.strpos(v_definition, 'public.get_encounter_scene_catalog()') = 0 THEN
    RAISE EXCEPTION 'unavailable scene intent is not filtered through the published scene catalog';
  END IF;

  IF pg_catalog.strpos(v_definition, 'public.resolve_encounter_scene_location_key') = 0 THEN
    RAISE EXCEPTION 'unmatched natural-language locations are not rematched by the system';
  END IF;

  SELECT pg_catalog.pg_get_functiondef(
    'public.get_encounter_character_schedules_with_scene(uuid[])'::regprocedure
  ) INTO v_definition;

  IF pg_catalog.strpos(v_definition, 'scene_description') = 0
     OR pg_catalog.strpos(v_definition, 'public.resolve_encounter_character_schedule') = 0 THEN
    RAISE EXCEPTION 'scene descriptions are not returned with resolved character schedules';
  END IF;

  SELECT pg_catalog.pg_get_functiondef(
    'public.publish_encounter_schedule_batch(uuid,uuid,jsonb)'::regprocedure
  ) INTO v_definition;

  IF pg_catalog.strpos(v_definition, 'location_description') = 0
     OR pg_catalog.strpos(v_definition, 'scene_description') = 0 THEN
    RAISE EXCEPTION 'publisher does not persist natural place intent and arrival description';
  END IF;
END;
$sparse_schedule_contract$;
