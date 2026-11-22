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

  v_old := 'IF (v_slot->>''is_outdoor'')::boolean IS TRUE THEN' || E'\\n' ||
    '            IF COALESCE(v_slot->>''rain_fallback_location_key'', '''') NOT IN (' || E'\\n' ||
    '              ''airport'', ''commercial'', ''night-bar'', ''live-house'', ''apartment'',' || E'\\n' ||
    '              ''department-store'', ''bookstore'', ''cafe''' || E'\\n' ||
    '            )' || E'\\n' ||
    '                 OR char_length(COALESCE(v_slot->>''rain_fallback_activity'', '''')) NOT BETWEEN 10 AND 30 THEN' || E'\\n' ||
    '              RAISE EXCEPTION ''schedule_hourly_option_rain_fallback_invalid'' USING ERRCODE = ''22023'';' || E'\\n' ||
    '            END IF;' || E'\\n' ||
    '          ELSIF v_slot->>''rain_fallback_location_key'' IS NOT NULL' || E'\\n' ||
    '             OR v_slot->>''rain_fallback_activity'' IS NOT NULL THEN' || E'\\n' ||
    '            RAISE EXCEPTION ''schedule_hourly_option_unexpected_rain_fallback'' USING ERRCODE = ''22023'';' || E'\\n' ||
    '          END IF;';
  v_new := 'IF (v_slot->>''is_outdoor'')::boolean IS TRUE' || E'\\n' ||
    '             AND v_slot->>''rain_fallback_activity'' IS NULL THEN' || E'\\n' ||
    '            RAISE EXCEPTION ''schedule_hourly_option_rain_fallback_missing'' USING ERRCODE = ''22023'';' || E'\\n' ||
    '          END IF;' || E'\\n' ||
    '          IF (' || E'\\n' ||
    '               v_slot->>''rain_fallback_location_key'' IS NOT NULL' || E'\\n' ||
    '               AND v_slot->>''rain_fallback_location_key'' NOT IN (' || E'\\n' ||
    '                 ''airport'', ''commercial'', ''night-bar'', ''live-house'', ''apartment'',' || E'\\n' ||
    '                 ''department-store'', ''bookstore'', ''cafe''' || E'\\n' ||
    '               )' || E'\\n' ||
    '             ) OR (' || E'\\n' ||
    '               v_slot->>''rain_fallback_location_key'' IS NOT NULL' || E'\\n' ||
    '               AND v_slot->>''rain_fallback_activity'' IS NULL' || E'\\n' ||
    '             ) OR (' || E'\\n' ||
    '               v_slot->>''rain_fallback_activity'' IS NOT NULL' || E'\\n' ||
    '               AND char_length(v_slot->>''rain_fallback_activity'') NOT BETWEEN 8 AND 30' || E'\\n' ||
    '             ) THEN' || E'\\n' ||
    '            RAISE EXCEPTION ''schedule_hourly_option_rain_fallback_invalid'' USING ERRCODE = ''22023'';' || E'\\n' ||
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
