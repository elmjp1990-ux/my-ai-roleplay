-- Allow a reviewed, unresolved manual schedule publish to be claimed again only
-- while its source is unchanged, no completion is recorded, and no active AI schedule exists.
DO $migration$
DECLARE
  v_definition text;
  v_old text := $old$AND j.status = 'failed'
    AND j.source_hash = p_expected_source_hash$old$;
  v_new text := $new$AND j.status IN ('failed', 'needs_reconciliation')
    AND j.source_hash = p_expected_source_hash
    AND j.last_completed_source_hash IS DISTINCT FROM p_expected_source_hash
    AND NOT EXISTS (
      SELECT 1
      FROM public.character_schedules s
      WHERE s.character_id = j.character_id
        AND s.source_type = 'ai'
        AND s.is_active IS TRUE
    )$new$;
BEGIN
  v_definition := pg_catalog.pg_get_functiondef(
    'public.claim_encounter_schedule_repair(uuid,uuid,uuid,text)'::regprocedure
  );
  IF pg_catalog.position(v_old IN v_definition) = 0 THEN
    RAISE EXCEPTION 'claim_encounter_schedule_repair_definition_unexpected';
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);
  EXECUTE v_definition;
END;
$migration$;
