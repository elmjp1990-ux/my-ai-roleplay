BEGIN;

DO $patch$
DECLARE
  v_definition text;
  v_old text := 's.encounter_greeting, s.is_outdoor, s.rain_fallback_location_key,';
  v_new text := 'COALESCE(s.encounter_greeting, ''''), s.is_outdoor, s.rain_fallback_location_key,';
  v_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.replace_character_schedules_from_editor(uuid,jsonb)'::regprocedure
  ) INTO v_definition;

  SELECT (
    pg_catalog.length(v_definition) -
    pg_catalog.length(pg_catalog.replace(v_definition, v_old, ''))
  ) / pg_catalog.length(v_old)
  INTO v_count;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'schedule_editor_nullable_greeting_patch_contract_unexpected: %', v_count;
  END IF;

  EXECUTE pg_catalog.replace(v_definition, v_old, v_new);
END;
$patch$;

COMMIT;
