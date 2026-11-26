-- Preserve existing encounter schedules unless an author changes schedule source fields.
-- Batch reconciliation must never requeue a character that already has active schedules.
BEGIN;

-- Clear stale pending entries for characters whose existing schedules are already usable.
-- Preserve every schedule row; a later author source edit will enqueue a fresh job.
UPDATE public.encounter_schedule_generation_jobs j
SET status = 'cancelled',
    lease_token = NULL,
    lease_expires_at = NULL,
    last_error_code = 'existing_active_schedules_preserved',
    completed_at = NULL,
    updated_at = pg_catalog.clock_timestamp()
WHERE j.status = 'pending'
  AND EXISTS (
    SELECT 1
    FROM public.character_schedules s
    WHERE s.character_id = j.character_id
      AND s.is_active IS TRUE
  );

CREATE OR REPLACE FUNCTION public.enqueue_encounter_schedule_generation_internal(
  p_character_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  RETURN public.enqueue_encounter_schedule_generation_internal(p_character_id, false);
END;
$function$;

CREATE OR REPLACE FUNCTION public.enqueue_encounter_schedule_generation_internal(
  p_character_id uuid,
  p_author_source_update boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_source jsonb;
  v_hash text;
  v_status text;
  v_existing_hash text;
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_has_active_schedule boolean := false;
BEGIN
  v_source := public.encounter_schedule_source_payload(p_character_id);

  IF v_source IS NULL THEN
    UPDATE public.encounter_schedule_generation_jobs
    SET status = 'cancelled', lease_token = NULL, lease_expires_at = NULL,
        worldview_review_decision = NULL, worldview_reviewed_by = NULL, worldview_reviewed_at = NULL,
        last_error_code = 'character_not_public_or_schedule_missing',
        updated_at = v_now
    WHERE character_id = p_character_id;

    UPDATE public.character_schedules
    SET is_active = false, updated_at = v_now
    WHERE character_id = p_character_id AND source_type = 'ai' AND is_active IS TRUE;

    RETURN pg_catalog.jsonb_build_object('status', 'not_eligible');
  END IF;

  v_hash := pg_catalog.md5(v_source::text);

  SELECT EXISTS (
    SELECT 1
    FROM public.character_schedules s
    WHERE s.character_id = p_character_id
      AND s.is_active IS TRUE
  ) INTO v_has_active_schedule;

  SELECT j.source_hash, j.status
  INTO v_existing_hash, v_status
  FROM public.encounter_schedule_generation_jobs j
  WHERE j.character_id = p_character_id
  FOR UPDATE;

  -- Existing schedules are authoritative during routine batch scans. Only a
  -- source change caused by an author save may schedule a replacement run.
  IF v_has_active_schedule AND p_author_source_update IS NOT TRUE THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', COALESCE(v_status, 'existing_schedules_preserved'),
      'skipped_existing_schedules', true,
      'ai_called', false
    );
  END IF;

  -- Do not enqueue a no-op save. A genuine source hash change is required.
  IF v_has_active_schedule
     AND p_author_source_update IS TRUE
     AND v_existing_hash IS NOT DISTINCT FROM v_hash THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', COALESCE(v_status, 'unchanged'),
      'skipped_unchanged_author_source', true,
      'ai_called', false
    );
  END IF;

  INSERT INTO public.encounter_schedule_generation_jobs (
    character_id, author_id, source_hash, status, queued_at, available_at,
    attempt_count, lease_token, lease_expires_at, lease_generation,
    last_error_code, completed_at, updated_at
  ) VALUES (
    p_character_id, (v_source->>'author_id')::uuid, v_hash, 'pending',
    v_now, v_now, 0, NULL, NULL, 1, NULL, NULL, v_now
  )
  ON CONFLICT (character_id) DO UPDATE
  SET author_id = EXCLUDED.author_id,
      source_hash = EXCLUDED.source_hash,
      worldview_review_decision = CASE WHEN public.encounter_schedule_generation_jobs.source_hash IS DISTINCT FROM EXCLUDED.source_hash THEN NULL ELSE public.encounter_schedule_generation_jobs.worldview_review_decision END,
      worldview_reviewed_by = CASE WHEN public.encounter_schedule_generation_jobs.source_hash IS DISTINCT FROM EXCLUDED.source_hash THEN NULL ELSE public.encounter_schedule_generation_jobs.worldview_reviewed_by END,
      worldview_reviewed_at = CASE WHEN public.encounter_schedule_generation_jobs.source_hash IS DISTINCT FROM EXCLUDED.source_hash THEN NULL ELSE public.encounter_schedule_generation_jobs.worldview_reviewed_at END,
      status = 'pending',
      queued_at = CASE
        WHEN public.encounter_schedule_generation_jobs.status IN
          ('pending', 'processing', 'failed', 'needs_reconciliation')
          THEN public.encounter_schedule_generation_jobs.queued_at
        ELSE v_now
      END,
      available_at = v_now,
      attempt_count = 0,
      lease_token = NULL,
      lease_expires_at = NULL,
      lease_generation = public.encounter_schedule_generation_jobs.lease_generation + 1,
      last_error_code = NULL,
      completed_at = NULL,
      updated_at = v_now
  WHERE (
      public.encounter_schedule_generation_jobs.status <> 'cancelled'
      AND public.encounter_schedule_generation_jobs.source_hash IS DISTINCT FROM EXCLUDED.source_hash
    )
     OR (
       public.encounter_schedule_generation_jobs.status = 'cancelled'
       AND public.encounter_schedule_generation_jobs.last_error_code IS DISTINCT FROM 'invalid_provider_response'
       AND public.encounter_schedule_generation_jobs.last_error_code IS DISTINCT FROM 'manual_cancelled_no_retry'
     )
  RETURNING status INTO v_status;

  IF v_status IS NULL THEN
    SELECT status INTO v_status
    FROM public.encounter_schedule_generation_jobs
    WHERE character_id = p_character_id;
  END IF;

  RETURN pg_catalog.jsonb_build_object('status', COALESCE(v_status, 'pending'));
END;
$function$;

REVOKE ALL ON FUNCTION public.enqueue_encounter_schedule_generation_internal(uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.enqueue_encounter_schedule_generation_internal(uuid, boolean) TO service_role;

CREATE OR REPLACE FUNCTION public.on_encounter_character_visibility_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.enqueue_encounter_schedule_generation_internal(NEW.id, true);
    RETURN NEW;
  END IF;

  IF OLD.author_id IS DISTINCT FROM NEW.author_id
     OR OLD.name IS DISTINCT FROM NEW.name
     OR OLD.title IS DISTINCT FROM NEW.title
     OR OLD.intro IS DISTINCT FROM NEW.intro
     OR OLD.race IS DISTINCT FROM NEW.race
     OR OLD.style IS DISTINCT FROM NEW.style
     OR OLD.gender IS DISTINCT FROM NEW.gender
     OR OLD.age IS DISTINCT FROM NEW.age
     OR OLD.tags IS DISTINCT FROM NEW.tags
     OR OLD.worldview_tags IS DISTINCT FROM NEW.worldview_tags
     OR OLD.personality_profile IS DISTINCT FROM NEW.personality_profile
     OR OLD.visibility IS DISTINCT FROM NEW.visibility
     OR OLD.review_status IS DISTINCT FROM NEW.review_status
     OR OLD.rights_confirmed IS DISTINCT FROM NEW.rights_confirmed
     OR OLD.deleted_at IS DISTINCT FROM NEW.deleted_at THEN
    PERFORM public.enqueue_encounter_schedule_generation_internal(NEW.id, true);
  END IF;
  RETURN NEW;
END;
$function$;

COMMIT;
