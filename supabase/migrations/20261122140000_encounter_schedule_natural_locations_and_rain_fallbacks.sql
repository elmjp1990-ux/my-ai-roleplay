-- Keep AI-generated natural place labels while allowing broad system-side scene mapping.
-- Unmapped places remain valid schedule entries with a NULL scene key.
-- Indoor schedules may keep a sensible optional rain alternative; outdoor schedules
-- still require a rain alternative activity. An unmapped fallback may retain a NULL key.

DO $$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
  v_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.publish_encounter_schedule_batch(uuid,uuid,jsonb)'::regprocedure
  ) INTO v_definition;

  v_old := '             OR pg_catalog.char_length(pg_catalog.regexp_replace(pg_catalog.btrim(COALESCE(v_slot->>''location_description'', '''')), ''[[:space:]]'', '''', ''g'')) NOT BETWEEN 1 AND 8';
  v_new := '             OR pg_catalog.char_length(pg_catalog.regexp_replace(pg_catalog.btrim(COALESCE(v_slot->>''location_description'', '''')), ''[[:space:]]'', '''', ''g'')) NOT BETWEEN 1 AND 20';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'schedule_natural_location_length_patch_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := '             OR char_length(COALESCE(v_slot->>''activity'', '''')) NOT BETWEEN 10 AND 30';
  v_new := '             OR char_length(COALESCE(v_slot->>''activity'', '''')) NOT BETWEEN 8 AND 30';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'schedule_natural_activity_length_patch_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := 'IF (v_slot->>''is_outdoor'')::boolean IS TRUE THEN' || chr(10) ||
    '            IF COALESCE(v_slot->>''rain_fallback_location_key'', '''') NOT IN (' || chr(10) ||
    '              ''airport'', ''commercial'', ''night-bar'', ''live-house'', ''apartment'',' || chr(10) ||
    '              ''department-store'', ''bookstore'', ''cafe''' || chr(10) ||
    '            )' || chr(10) ||
    '                 OR char_length(COALESCE(v_slot->>''rain_fallback_activity'', '''')) NOT BETWEEN 10 AND 30 THEN' || chr(10) ||
    '              RAISE EXCEPTION ''schedule_hourly_option_rain_fallback_invalid'' USING ERRCODE = ''22023'';' || chr(10) ||
    '            END IF;' || chr(10) ||
    '          ELSIF v_slot->>''rain_fallback_location_key'' IS NOT NULL' || chr(10) ||
    '             OR v_slot->>''rain_fallback_activity'' IS NOT NULL THEN' || chr(10) ||
    '            RAISE EXCEPTION ''schedule_hourly_option_unexpected_rain_fallback'' USING ERRCODE = ''22023'';' || chr(10) ||
    '          END IF;';
  v_new := 'IF (v_slot->>''is_outdoor'')::boolean IS TRUE' || chr(10) ||
    '             AND v_slot->>''rain_fallback_activity'' IS NULL THEN' || chr(10) ||
    '            RAISE EXCEPTION ''schedule_hourly_option_rain_fallback_missing'' USING ERRCODE = ''22023'';' || chr(10) ||
    '          END IF;' || chr(10) ||
    '          IF (' || chr(10) ||
    '               v_slot->>''rain_fallback_location_key'' IS NOT NULL' || chr(10) ||
    '               AND v_slot->>''rain_fallback_location_key'' NOT IN (' || chr(10) ||
    '                 ''airport'', ''commercial'', ''night-bar'', ''live-house'', ''apartment'',' || chr(10) ||
    '                 ''department-store'', ''bookstore'', ''cafe''' || chr(10) ||
    '               )' || chr(10) ||
    '             ) OR (' || chr(10) ||
    '               v_slot->>''rain_fallback_location_key'' IS NOT NULL' || chr(10) ||
    '               AND v_slot->>''rain_fallback_activity'' IS NULL' || chr(10) ||
    '             ) OR (' || chr(10) ||
    '               v_slot->>''rain_fallback_activity'' IS NOT NULL' || chr(10) ||
    '               AND char_length(v_slot->>''rain_fallback_activity'') NOT BETWEEN 8 AND 30' || chr(10) ||
    '             ) THEN' || chr(10) ||
    '            RAISE EXCEPTION ''schedule_hourly_option_rain_fallback_invalid'' USING ERRCODE = ''22023'';' || chr(10) ||
    '          END IF;';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'schedule_natural_rain_fallback_patch_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  EXECUTE v_definition;
END;
$$;
