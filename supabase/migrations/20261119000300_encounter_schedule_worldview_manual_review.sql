BEGIN;

-- Unknown worldview is neither a successful unplaced result nor a retryable
-- generation failure. Keep it queued for explicit human classification.
ALTER TABLE public.encounter_schedule_generation_jobs
  DROP CONSTRAINT IF EXISTS encounter_schedule_generation_jobs_status_check;

ALTER TABLE public.encounter_schedule_generation_jobs
  ADD CONSTRAINT encounter_schedule_generation_jobs_status_check
  CHECK (status IN (
    'pending', 'processing', 'failed', 'needs_reconciliation',
    'needs_review', 'completed', 'cancelled'
  ));

DO $publisher$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
  v_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.publish_encounter_schedule_batch(uuid,uuid,jsonb)'::regprocedure
  ) INTO v_definition;

  v_old := '    v_placement := v_item->>''placement'';' || E'\n' ||
    '    IF v_placement = ''no_matching_location'' THEN';
  v_new := '    v_placement := v_item->>''placement'';' || E'\n' ||
    '    IF v_placement = ''needs_review'' THEN' || E'\n' ||
    '      -- Preserve existing schedules and greeting data while the author/admin reviews worldview.' || E'\n' ||
    '      UPDATE public.encounter_schedule_generation_jobs' || E'\n' ||
    '      SET status = ''needs_review'', lease_token = NULL, lease_expires_at = NULL,' || E'\n' ||
    '          last_error_code = ''worldview_manual_review_required'', updated_at = pg_catalog.clock_timestamp()' || E'\n' ||
    '      WHERE character_id = v_character_id;' || E'\n' ||
    '      CONTINUE;' || E'\n' ||
    '    END IF;' || E'\n' ||
    '    IF v_placement = ''no_matching_location'' THEN';

  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'worldview_manual_review_publisher_anchor_count_unexpected: %', v_count;
  END IF;

  v_definition := pg_catalog.replace(v_definition, v_old, v_new);
  EXECUTE v_definition;
END;
$publisher$;

COMMENT ON CONSTRAINT encounter_schedule_generation_jobs_status_check
  ON public.encounter_schedule_generation_jobs IS
  'needs_review is a terminal queue hold for unknown worldview; it is excluded from automatic claims until an explicit manual decision requeues or resolves it.';

COMMENT ON FUNCTION public.publish_encounter_schedule_batch(uuid,uuid,jsonb) IS
  'Publishes Encounter schedules; needs_review holds unknown-worldview jobs without modifying existing schedules or greeting pools.';

COMMIT;
