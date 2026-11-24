BEGIN;

-- Keep the database publisher aligned with the application parser:
-- activity descriptions may contain 8-30 characters (not 10-30).
-- This only changes validation for future manual schedule publishes.
-- It does not rewrite existing schedules or revisions and does not call AI.
DO $publisher$
DECLARE
  v_definition text;
  v_old text := 'NOT BETWEEN 10 AND 30';
  v_new text := 'NOT BETWEEN 8 AND 30';
  v_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.publish_encounter_schedule_batch(uuid,uuid,jsonb)'::regprocedure
  ) INTO v_definition;

  SELECT (
    pg_catalog.length(v_definition) -
    pg_catalog.length(pg_catalog.replace(v_definition, v_old, ''))
  ) / pg_catalog.length(v_old)
  INTO v_count;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'encounter_schedule_activity_min_length_contract_count_unexpected: %', v_count;
  END IF;

  v_definition := pg_catalog.replace(v_definition, v_old, v_new);
  EXECUTE v_definition;
END;
$publisher$;

COMMIT;
