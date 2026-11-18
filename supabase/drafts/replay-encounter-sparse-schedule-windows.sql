DO $sparse_schedule_contract$
DECLARE
  v_definition text;
  v_original_aliases text[];
  v_resolved_key text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.publish_encounter_schedule_batch(uuid,uuid,jsonb)'::regprocedure
  ) INTO v_definition;

  IF pg_catalog.strpos(v_definition, 'schedule_variant_24_hour_coverage_incomplete') > 0
     OR pg_catalog.strpos(v_definition, 'schedule_special_event_24_hour_coverage_incomplete') > 0 THEN
    RAISE EXCEPTION 'sparse encounter schedules still require full-day coverage';
  END IF;

  IF pg_catalog.strpos(v_definition, 'jsonb_array_length(v_item->''variants''->v_day_type) > 24') = 0
     OR pg_catalog.strpos(v_definition, 'jsonb_array_length(v_variant->''options'') NOT BETWEEN 1 AND 3') = 0
     OR pg_catalog.strpos(v_definition, 'schedule_hourly_option_weights_must_sum_100') = 0
     OR pg_catalog.strpos(v_definition, 'schedule_hourly_block_must_be_exactly_one_hour') = 0 THEN
    RAISE EXCEPTION 'hourly sparse schedule bounds and option weights are missing';
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

  SELECT aliases INTO v_original_aliases
  FROM public.encounter_scene_registry
  WHERE location_key = 'commercial';
  UPDATE public.encounter_scene_registry
  SET aliases = pg_catalog.array_append(aliases, '回歸測試新地點名稱')
  WHERE location_key = 'commercial';
  SELECT public.resolve_encounter_scene_location_key('回歸測試新地點名稱')
    INTO v_resolved_key;
  UPDATE public.encounter_scene_registry
  SET aliases = v_original_aliases
  WHERE location_key = 'commercial';
  IF v_resolved_key IS DISTINCT FROM 'commercial' THEN
    RAISE EXCEPTION 'new scene aliases do not rematch retained natural-language intent';
  END IF;

  SELECT pg_catalog.pg_get_functiondef(
    'public.publish_encounter_scene_metadata(jsonb)'::regprocedure
  ) INTO v_definition;
  IF pg_catalog.strpos(v_definition, 'resolve_encounter_scene_location_key') = 0 THEN
    RAISE EXCEPTION 'dynamic scene eligibility ignores retained unmatched place intents';
  END IF;
END;
$sparse_schedule_contract$;
