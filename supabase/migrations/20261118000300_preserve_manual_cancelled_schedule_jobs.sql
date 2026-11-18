-- Explicitly operator-cancelled validation failures are terminal and must not
-- be silently requeued by the broad manual enqueue scan. A future retry requires
-- an explicit operator decision and a separate status transition.

CREATE OR REPLACE FUNCTION public.enqueue_encounter_schedule_generation_internal(p_character_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_source jsonb;
  v_hash text;
  v_status text;
  v_now timestamptz := pg_catalog.clock_timestamp();
BEGIN
  v_source := public.encounter_schedule_source_payload(p_character_id);

  IF v_source IS NULL THEN
    UPDATE public.encounter_schedule_generation_jobs
    SET status = 'cancelled', lease_token = NULL, lease_expires_at = NULL,
        last_error_code = 'character_not_public_or_schedule_missing',
        updated_at = v_now
    WHERE character_id = p_character_id;

    UPDATE public.character_schedules
    SET is_active = false, updated_at = v_now
    WHERE character_id = p_character_id AND source_type = 'ai' AND is_active IS TRUE;

    RETURN pg_catalog.jsonb_build_object('status', 'not_eligible');
  END IF;

  v_hash := pg_catalog.md5(v_source::text);
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
$$;

REVOKE ALL ON FUNCTION public.enqueue_encounter_schedule_generation_internal(uuid)
  FROM PUBLIC, anon, authenticated;
