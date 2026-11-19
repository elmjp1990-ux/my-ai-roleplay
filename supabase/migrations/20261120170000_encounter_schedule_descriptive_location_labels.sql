-- Permit descriptive venue labels such as "歸途（酒吧）" in repaired/published schedule records.
-- Keep the special-event slot count limit unchanged.
DO $$
DECLARE
  v_function_definition text;
  v_old_expression text := 'pg_catalog.char_length(pg_catalog.regexp_replace(pg_catalog.btrim(COALESCE(v_slot->>''location_description'', '''')), ''[[:space:]]'', '''', ''g'')) NOT BETWEEN 1 AND 4';
  v_new_expression text := 'pg_catalog.char_length(pg_catalog.regexp_replace(pg_catalog.btrim(COALESCE(v_slot->>''location_description'', '''')), ''[[:space:]]'', '''', ''g'')) NOT BETWEEN 1 AND 8';
BEGIN
  v_function_definition := pg_catalog.pg_get_functiondef('public.publish_encounter_schedule_batch(uuid,uuid,jsonb)'::regprocedure);
  IF pg_catalog.position(v_old_expression in v_function_definition) = 0 THEN
    RAISE EXCEPTION 'expected schedule location label validation expression not found';
  END IF;
  v_function_definition := pg_catalog.replace(v_function_definition, v_old_expression, v_new_expression);
  EXECUTE v_function_definition;
END;
$$;
