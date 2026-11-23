-- Require 2-3 weighted alternatives in every hourly block and keep location labels concise.
-- The existing publisher was already hardened by earlier migrations; patch its definition
-- without weakening the lease, ownership, or wallet-isolation checks.
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

  v_old := '        IF jsonb_array_length(v_variant->''options'') NOT BETWEEN 1 AND 3 THEN' || E'\n' ||
    '          RAISE EXCEPTION ''schedule_hourly_options_count_invalid'' USING ERRCODE = ''22023'';' || E'\n' ||
    '        END IF;';
  v_new := '        IF jsonb_array_length(v_variant->''options'') NOT BETWEEN 2 AND 3 THEN' || E'\n' ||
    '          RAISE EXCEPTION ''schedule_hourly_options_count_invalid'' USING ERRCODE = ''22023'';' || E'\n' ||
    '        END IF;';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'strict_schedule_options_count_contract_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := '      IF v_multi_option_hours < 8 THEN' || E'\n' ||
    '        RAISE EXCEPTION ''schedule_hourly_too_few_multi_option_hours'' USING ERRCODE = ''22023'';' || E'\n' ||
    '      END IF;' || E'\n';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'strict_schedule_options_floor_contract_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, '');

  v_old := '             OR char_length(COALESCE(v_slot->>''location_description'', '''')) NOT BETWEEN 1 AND 120';
  v_new := '             OR pg_catalog.char_length(pg_catalog.regexp_replace(pg_catalog.btrim(COALESCE(v_slot->>''location_description'', '''')), ''[[:space:]]'', '''', ''g'')) NOT BETWEEN 1 AND 4';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'strict_schedule_location_length_contract_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  EXECUTE v_definition;
END;
$$;
