BEGIN;

-- A terminal failed test job must not starve newer pending characters when
-- the one-character manual test worker is invoked repeatedly.
DO $priority$
DECLARE
  v_definition text;
  v_old text := 'ORDER BY j.queued_at, j.character_id';
  v_new text := 'ORDER BY CASE j.status WHEN ''pending'' THEN 0 WHEN ''failed'' THEN 1 ELSE 2 END, j.queued_at, j.character_id';
  v_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.claim_encounter_schedule_batch(integer,boolean,uuid)'::regprocedure
  ) INTO v_definition;

  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;

  IF v_count = 1 THEN
    v_definition := pg_catalog.replace(v_definition, v_old, v_new);
    EXECUTE v_definition;
  ELSIF v_count = 0 AND pg_catalog.strpos(v_definition, v_new) > 0 THEN
    NULL;
  ELSE
    RAISE EXCEPTION 'pending_schedule_job_priority_contract_count_unexpected: %', v_count;
  END IF;
END;
$priority$;

COMMIT;
