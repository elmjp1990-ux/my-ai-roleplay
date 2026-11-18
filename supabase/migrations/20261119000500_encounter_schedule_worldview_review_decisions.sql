-- Explicit author decisions for unknown Encounter worldviews.
-- Decisions never call AI in this RPC. "modern_map_compatible" only queues the
-- character for a later worker run; "not_applicable" completes the review while
-- preserving all existing schedules and relationship greeting pools.

ALTER TABLE public.encounter_schedule_generation_jobs
  ADD COLUMN IF NOT EXISTS worldview_review_decision text,
  ADD COLUMN IF NOT EXISTS worldview_reviewed_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS worldview_reviewed_at timestamptz;

DO $constraint$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_constraint
    WHERE conrelid = 'public.encounter_schedule_generation_jobs'::regclass
      AND conname = 'encounter_schedule_jobs_worldview_review_decision_check'
  ) THEN
    ALTER TABLE public.encounter_schedule_generation_jobs
      ADD CONSTRAINT encounter_schedule_jobs_worldview_review_decision_check
      CHECK (worldview_review_decision IS NULL OR worldview_review_decision IN ('modern_map_compatible', 'not_applicable'));
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_constraint
    WHERE conrelid = 'public.encounter_schedule_generation_jobs'::regclass
      AND conname = 'encounter_schedule_jobs_worldview_review_audit_check'
  ) THEN
    ALTER TABLE public.encounter_schedule_generation_jobs
      ADD CONSTRAINT encounter_schedule_jobs_worldview_review_audit_check
      CHECK (
        (worldview_review_decision IS NULL AND worldview_reviewed_at IS NULL)
        OR (worldview_review_decision IS NOT NULL AND worldview_reviewed_at IS NOT NULL)
      );
  END IF;
END;
$constraint$;

CREATE INDEX IF NOT EXISTS encounter_schedule_jobs_author_review_idx
  ON public.encounter_schedule_generation_jobs (author_id, updated_at DESC)
  WHERE status = 'needs_review';

DO $enqueue_patch$
DECLARE
  v_definition text;
  v_old text := '      source_hash = EXCLUDED.source_hash,';
  v_new text := '      source_hash = EXCLUDED.source_hash,' || E'\n' ||
    '      worldview_review_decision = CASE WHEN public.encounter_schedule_generation_jobs.source_hash IS DISTINCT FROM EXCLUDED.source_hash THEN NULL ELSE public.encounter_schedule_generation_jobs.worldview_review_decision END,' || E'\n' ||
    '      worldview_reviewed_by = CASE WHEN public.encounter_schedule_generation_jobs.source_hash IS DISTINCT FROM EXCLUDED.source_hash THEN NULL ELSE public.encounter_schedule_generation_jobs.worldview_reviewed_by END,' || E'\n' ||
    '      worldview_reviewed_at = CASE WHEN public.encounter_schedule_generation_jobs.source_hash IS DISTINCT FROM EXCLUDED.source_hash THEN NULL ELSE public.encounter_schedule_generation_jobs.worldview_reviewed_at END,';
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.enqueue_encounter_schedule_generation_internal(uuid)'::regprocedure
  ) INTO v_definition;
  IF pg_catalog.strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'worldview_review_enqueue_anchor_missing';
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);
  EXECUTE v_definition;
END;
$enqueue_patch$;

DO $claim_patch$
DECLARE
  v_definition text;
  v_filter_old text := 'WHERE j.status IN (''pending'', ''failed'', ''needs_reconciliation'')' || E'\n' ||
    '    AND (p_force IS TRUE OR j.available_at <= v_now)';
  v_filter_new text := 'WHERE j.status IN (''pending'', ''failed'', ''needs_reconciliation'')' || E'\n' ||
    '    AND (p_force IS NOT TRUE OR j.author_id = p_actor_user_id)' || E'\n' ||
    '    AND (p_force IS TRUE OR j.available_at <= v_now)';
  v_payload_old text := '  SELECT pg_catalog.jsonb_agg(public.encounter_schedule_source_payload(x.character_id))' || E'\n' ||
    '  INTO v_characters' || E'\n' ||
    '  FROM pg_catalog.unnest(v_ids) AS x(character_id);';
  v_payload_new text := '  SELECT pg_catalog.jsonb_agg(' || E'\n' ||
    '    public.encounter_schedule_source_payload(x.character_id) ||' || E'\n' ||
    '    pg_catalog.jsonb_build_object(''worldview_review_decision'', j.worldview_review_decision)' || E'\n' ||
    '  )' || E'\n' ||
    '  INTO v_characters' || E'\n' ||
    '  FROM pg_catalog.unnest(v_ids) AS x(character_id)' || E'\n' ||
    '  JOIN public.encounter_schedule_generation_jobs j ON j.character_id = x.character_id;';
  v_filter_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.claim_encounter_schedule_batch(integer,boolean,uuid)'::regprocedure
  ) INTO v_definition;

  v_filter_count := (
    pg_catalog.length(v_definition) -
    pg_catalog.length(pg_catalog.replace(v_definition, v_filter_old, ''))
  ) / pg_catalog.length(v_filter_old);
  IF v_filter_count <> 2 THEN
    RAISE EXCEPTION 'worldview_review_claim_filter_anchor_count_unexpected: %', v_filter_count;
  END IF;
  IF pg_catalog.strpos(v_definition, v_payload_old) = 0 THEN
    RAISE EXCEPTION 'worldview_review_claim_payload_anchor_missing';
  END IF;

  v_definition := pg_catalog.replace(v_definition, v_filter_old, v_filter_new);
  v_definition := pg_catalog.replace(v_definition, v_payload_old, v_payload_new);
  EXECUTE v_definition;
END;
$claim_patch$;

CREATE OR REPLACE FUNCTION public.review_encounter_schedule_worldview(
  p_character_id uuid,
  p_decision text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_character public.characters%ROWTYPE;
  v_job public.encounter_schedule_generation_jobs%ROWTYPE;
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_status text;
BEGIN
  IF v_user_id IS NULL OR public.account_is_active() IS NOT TRUE THEN
    RAISE EXCEPTION 'active_authentication_required' USING ERRCODE = '42501';
  END IF;
  IF p_character_id IS NULL OR p_decision NOT IN ('modern_map_compatible', 'not_applicable') THEN
    RAISE EXCEPTION 'worldview_review_decision_invalid' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_character
  FROM public.characters c
  WHERE c.id = p_character_id AND c.author_id = v_user_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'character_not_found_or_not_owned' USING ERRCODE = '42501';
  END IF;
  IF v_character.visibility <> 'public'
     OR v_character.review_status <> 'approved'
     OR v_character.rights_confirmed IS NOT TRUE
     OR v_character.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'character_not_eligible_for_encounter_schedule' USING ERRCODE = '40901';
  END IF;

  SELECT * INTO v_job
  FROM public.encounter_schedule_generation_jobs j
  WHERE j.character_id = p_character_id
    AND j.author_id = v_user_id
    AND j.status = 'needs_review'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'worldview_review_job_not_found_or_already_resolved' USING ERRCODE = '40001';
  END IF;

  IF p_decision = 'modern_map_compatible' THEN
    UPDATE public.encounter_schedule_generation_jobs
    SET worldview_review_decision = p_decision,
        worldview_reviewed_by = v_user_id,
        worldview_reviewed_at = v_now,
        status = 'pending',
        queued_at = v_now,
        available_at = v_now,
        attempt_count = 0,
        lease_token = NULL,
        lease_expires_at = NULL,
        lease_generation = lease_generation + 1,
        last_error_code = NULL,
        completed_at = NULL,
        updated_at = v_now
    WHERE character_id = p_character_id
      AND author_id = v_user_id
      AND status = 'needs_review'
      AND source_hash = v_job.source_hash
    RETURNING status INTO v_status;
  ELSE
    UPDATE public.encounter_schedule_generation_jobs
    SET worldview_review_decision = p_decision,
        worldview_reviewed_by = v_user_id,
        worldview_reviewed_at = v_now,
        status = 'completed',
        last_completed_source_hash = v_job.source_hash,
        completed_at = v_now,
        lease_token = NULL,
        lease_expires_at = NULL,
        last_error_code = 'worldview_reviewed_not_applicable',
        updated_at = v_now
    WHERE character_id = p_character_id
      AND author_id = v_user_id
      AND status = 'needs_review'
      AND source_hash = v_job.source_hash
    RETURNING status INTO v_status;
  END IF;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'worldview_review_job_changed_retry' USING ERRCODE = '40001';
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'status', v_status,
    'decision', p_decision,
    'ai_invoked', false,
    'existing_schedules_preserved', true
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.review_encounter_schedule_worldview(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_encounter_schedule_worldview(uuid,text) TO authenticated;

COMMENT ON COLUMN public.encounter_schedule_generation_jobs.worldview_review_decision IS
  'Author-reviewed override for an otherwise unknown worldview. A modern_map_compatible decision queues a later worker run; not_applicable completes review without modifying existing schedules or greeting pools.';
COMMENT ON FUNCTION public.review_encounter_schedule_worldview(uuid,text) IS
  'Allows a character author to resolve their own unknown-worldview schedule hold. This RPC never invokes AI; modern-map approval only queues work, while not-applicable preserves existing schedules and greeting pools.';
