-- The schedule generator intentionally omits encounter greetings for hourly options.
-- Keep the weather-decision snapshot compatible with that contract: the table requires
-- a non-null greeting, so store an empty string when the source schedule has none.
DO $$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
  v_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.resolve_encounter_character_schedule(uuid,uuid,text,timestamp with time zone)'::regprocedure
  ) INTO v_definition;

  v_old := '        v_effective_location, v_effective_activity, v_effective_greeting,' || E'\n' ||
    '        v_effective_is_outdoor, v_weather_text, v_is_raining';
  v_new := '        v_effective_location, v_effective_activity, COALESCE(v_effective_greeting, ''''),' || E'\n' ||
    '        v_effective_is_outdoor, v_weather_text, v_is_raining';

  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'schedule_weather_decision_null_greeting_patch_unexpected: %', v_count;
  END IF;

  EXECUTE pg_catalog.replace(v_definition, v_old, v_new);
END;
$$;
