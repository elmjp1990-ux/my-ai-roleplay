BEGIN;

CREATE OR REPLACE FUNCTION public.replace_character_schedules_from_editor(
  p_character_id uuid,
  p_rows jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_updated integer := 0;
  v_inserted integer := 0;
  v_deleted integer := 0;
  v_total integer := 0;
BEGIN
  IF p_character_id IS NULL OR pg_catalog.jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'schedule_payload_must_be_array';
  END IF;

  IF pg_catalog.jsonb_array_length(p_rows) < 1
     OR pg_catalog.jsonb_array_length(p_rows) > 500 THEN
    RAISE EXCEPTION 'schedule_row_count_out_of_range';
  END IF;

  PERFORM 1
  FROM public.characters c
  WHERE c.id = p_character_id
    AND c.author_id = (SELECT auth.uid())
    AND c.deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'character_not_found_or_not_authorized';
  END IF;

  DROP TABLE IF EXISTS pg_temp.poyozz_schedule_editor_input;
  CREATE TEMP TABLE poyozz_schedule_editor_input (
    weekday smallint,
    day_type text NOT NULL,
    start_time time NOT NULL,
    end_time time NOT NULL,
    location_key text,
    location_description text NOT NULL DEFAULT '',
    activity text NOT NULL,
    scene_description text NOT NULL DEFAULT '',
    priority smallint NOT NULL DEFAULT 0,
    is_active boolean NOT NULL DEFAULT true,
    variant_key text NOT NULL,
    variant_weight smallint NOT NULL DEFAULT 100,
    special_event_key text,
    encounter_greeting text NOT NULL DEFAULT '',
    is_outdoor boolean NOT NULL DEFAULT false,
    rain_fallback_location_key text,
    rain_fallback_activity text,
    rain_fallback_greeting text,
    existing_id uuid
  ) ON COMMIT DROP;

  INSERT INTO pg_temp.poyozz_schedule_editor_input (
    weekday, day_type, start_time, end_time, location_key,
    location_description, activity, scene_description, priority,
    is_active, variant_key, variant_weight, special_event_key,
    encounter_greeting, is_outdoor, rain_fallback_location_key,
    rain_fallback_activity, rain_fallback_greeting
  )
  SELECT
    r.weekday,
    COALESCE(NULLIF(r.day_type, ''), 'any'),
    r.start_time,
    r.end_time,
    r.location_key,
    COALESCE(r.location_description, ''),
    r.activity,
    COALESCE(r.scene_description, ''),
    COALESCE(r.priority, 0),
    COALESCE(r.is_active, true),
    COALESCE(NULLIF(r.variant_key, ''), 'primary'),
    COALESCE(r.variant_weight, 100),
    r.special_event_key,
    COALESCE(r.encounter_greeting, ''),
    COALESCE(r.is_outdoor, false),
    r.rain_fallback_location_key,
    r.rain_fallback_activity,
    r.rain_fallback_greeting
  FROM pg_catalog.jsonb_to_recordset(p_rows) AS r(
    weekday smallint,
    day_type text,
    start_time time,
    end_time time,
    location_key text,
    location_description text,
    activity text,
    scene_description text,
    priority smallint,
    is_active boolean,
    variant_key text,
    variant_weight smallint,
    special_event_key text,
    encounter_greeting text,
    is_outdoor boolean,
    rain_fallback_location_key text,
    rain_fallback_activity text,
    rain_fallback_greeting text
  );

  SELECT count(*) INTO v_total
  FROM pg_temp.poyozz_schedule_editor_input;

  IF EXISTS (
    SELECT 1
    FROM pg_temp.poyozz_schedule_editor_input
    WHERE pg_catalog.btrim(activity) = ''
       OR start_time = end_time
       OR day_type NOT IN ('weekday', 'holiday', 'any')
       OR pg_catalog.char_length(activity) > 200
       OR pg_catalog.char_length(location_description) > 120
       OR pg_catalog.char_length(scene_description) > 500
  ) THEN
    RAISE EXCEPTION 'schedule_row_validation_failed';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_temp.poyozz_schedule_editor_input
    GROUP BY day_type, start_time, end_time, variant_key, special_event_key
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'duplicate_schedule_slot_variant';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.character_schedules s
    WHERE s.character_id = p_character_id
      AND s.is_active IS TRUE
    GROUP BY s.day_type, s.start_time, s.end_time, s.variant_key, s.special_event_key
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'existing_schedule_slot_variant_not_unique';
  END IF;

  -- Match by the schedule slot identity, never by client-supplied IDs.
  -- Existing IDs are retained for rows whose slot identity is unchanged.
  UPDATE pg_temp.poyozz_schedule_editor_input i
  SET existing_id = s.id
  FROM public.character_schedules s
  WHERE s.character_id = p_character_id
    AND s.is_active IS TRUE
    AND s.day_type = i.day_type
    AND s.start_time = i.start_time
    AND s.end_time = i.end_time
    AND s.variant_key = i.variant_key
    AND s.special_event_key IS NOT DISTINCT FROM i.special_event_key;

  UPDATE public.character_schedules s
  SET
    weekday = i.weekday,
    day_type = i.day_type,
    start_time = i.start_time,
    end_time = i.end_time,
    location_key = i.location_key,
    location_description = i.location_description,
    activity = i.activity,
    scene_description = i.scene_description,
    priority = i.priority,
    is_active = i.is_active,
    source_type = 'manual',
    variant_key = i.variant_key,
    variant_weight = i.variant_weight,
    special_event_key = i.special_event_key,
    encounter_greeting = i.encounter_greeting,
    is_outdoor = i.is_outdoor,
    rain_fallback_location_key = i.rain_fallback_location_key,
    rain_fallback_activity = i.rain_fallback_activity,
    rain_fallback_greeting = i.rain_fallback_greeting,
    updated_at = pg_catalog.clock_timestamp()
  FROM pg_temp.poyozz_schedule_editor_input i
  WHERE i.existing_id = s.id
    AND s.character_id = p_character_id
    AND ROW(
      s.weekday, s.day_type, s.start_time, s.end_time, s.location_key,
      s.location_description, s.activity, s.scene_description, s.priority,
      s.is_active, s.variant_key, s.variant_weight, s.special_event_key,
      s.encounter_greeting, s.is_outdoor, s.rain_fallback_location_key,
      s.rain_fallback_activity, s.rain_fallback_greeting
    ) IS DISTINCT FROM ROW(
      i.weekday, i.day_type, i.start_time, i.end_time, i.location_key,
      i.location_description, i.activity, i.scene_description, i.priority,
      i.is_active, i.variant_key, i.variant_weight, i.special_event_key,
      i.encounter_greeting, i.is_outdoor, i.rain_fallback_location_key,
      i.rain_fallback_activity, i.rain_fallback_greeting
    );

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  INSERT INTO public.character_schedules (
    character_id, weekday, day_type, start_time, end_time, location_key,
    location_description, activity, scene_description, priority, is_active,
    source_type, variant_key, variant_weight, special_event_key,
    encounter_greeting, is_outdoor, rain_fallback_location_key,
    rain_fallback_activity, rain_fallback_greeting
  )
  SELECT
    p_character_id, i.weekday, i.day_type, i.start_time, i.end_time,
    i.location_key, i.location_description, i.activity, i.scene_description,
    i.priority, i.is_active, 'manual', i.variant_key, i.variant_weight,
    i.special_event_key, i.encounter_greeting, i.is_outdoor,
    i.rain_fallback_location_key, i.rain_fallback_activity,
    i.rain_fallback_greeting
  FROM pg_temp.poyozz_schedule_editor_input i
  WHERE i.existing_id IS NULL;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  DELETE FROM public.character_schedules s
  WHERE s.character_id = p_character_id
    AND s.is_active IS TRUE
    AND NOT EXISTS (
      SELECT 1
      FROM pg_temp.poyozz_schedule_editor_input i
      WHERE i.existing_id = s.id
    );

  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN pg_catalog.jsonb_build_object(
    'updated', v_updated,
    'inserted', v_inserted,
    'deleted', v_deleted,
    'total', v_total
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.replace_character_schedules_from_editor(uuid, jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.replace_character_schedules_from_editor(uuid, jsonb)
  TO authenticated;

COMMIT;
