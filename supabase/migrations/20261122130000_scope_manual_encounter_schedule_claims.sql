-- Fix manual schedule claims to enforce the same author scope in the actual
-- candidate selection that is already used by the pending-count preflight.
-- Without this predicate, a TEST manual click could claim another author's job.
CREATE OR REPLACE FUNCTION public.claim_encounter_schedule_batch(
  p_limit integer DEFAULT 2147483647,
  p_force boolean DEFAULT false,
  p_actor_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_limit integer := GREATEST(COALESCE(p_limit, 2147483647), 1);
  v_pending_count integer := 0;
  v_oldest timestamptz;
  v_last_completed timestamptz;
  v_lease uuid := gen_random_uuid();
  v_batch uuid;
  v_ids uuid[];
  v_characters jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF p_force IS TRUE AND p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'manual_actor_required' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('poyozz_encounter_schedule_batch')::bigint);

  UPDATE public.encounter_schedule_generation_jobs
  SET status = 'needs_reconciliation',
      available_at = v_now + interval '6 hours',
      lease_token = NULL,
      lease_expires_at = NULL,
      last_error_code = 'worker_lease_expired',
      updated_at = v_now
  WHERE status = 'processing'
    AND lease_expires_at IS NOT NULL
    AND lease_expires_at < v_now
    AND (p_force IS NOT TRUE OR author_id = p_actor_user_id);

  UPDATE public.encounter_schedule_batch_runs
  SET status = 'needs_reconciliation',
      failure_code = COALESCE(failure_code, 'worker_lease_expired'),
      updated_at = v_now
  WHERE status = 'processing'
    AND started_at < v_now - interval '20 minutes'
    AND (p_force IS NOT TRUE OR actor_user_id = p_actor_user_id);

  SELECT COUNT(DISTINCT j.character_id), MIN(j.queued_at)
  INTO v_pending_count, v_oldest
  FROM public.encounter_schedule_generation_jobs j
  JOIN public.characters c ON c.id = j.character_id
  LEFT JOIN public.character_schedule_descriptions d
    ON d.character_id = j.character_id AND d.author_id = j.author_id
  WHERE j.status IN ('pending', 'failed', 'needs_reconciliation')
    AND (p_force IS NOT TRUE OR j.author_id = p_actor_user_id)
    AND (p_force IS TRUE OR j.available_at <= v_now)
    AND c.author_id = j.author_id
    AND c.visibility = 'public'
    AND c.review_status = 'approved'
    AND c.rights_confirmed IS TRUE
    AND c.deleted_at IS NULL;

  IF p_force IS NOT TRUE THEN
    IF v_pending_count < 10
       AND (v_oldest IS NULL OR v_oldest > v_now - interval '24 hours') THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'waiting_threshold',
        'pending_character_count', v_pending_count,
        'oldest_queued_at', v_oldest
      );
    END IF;

    SELECT MAX(b.completed_at) INTO v_last_completed
    FROM public.encounter_schedule_batch_runs b
    WHERE b.status = 'completed'
      AND b.completed_at IS NOT NULL;

    IF v_last_completed IS NOT NULL
       AND v_last_completed > v_now - interval '6 hours' THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'cooldown',
        'pending_character_count', v_pending_count,
        'next_eligible_at', v_last_completed + interval '6 hours'
      );
    END IF;
  END IF;

  WITH candidates AS (
    SELECT j.character_id
    FROM public.encounter_schedule_generation_jobs j
    JOIN public.characters c ON c.id = j.character_id
    LEFT JOIN public.character_schedule_descriptions d
      ON d.character_id = j.character_id AND d.author_id = j.author_id
    WHERE j.status IN ('pending', 'failed', 'needs_reconciliation')
      AND (p_force IS NOT TRUE OR j.author_id = p_actor_user_id)
      AND (p_force IS TRUE OR j.available_at <= v_now)
      AND (p_force IS TRUE OR j.attempt_count < 3 OR j.status = 'needs_reconciliation')
      AND c.author_id = j.author_id
      AND c.visibility = 'public'
      AND c.review_status = 'approved'
      AND c.rights_confirmed IS TRUE
      AND c.deleted_at IS NULL
    ORDER BY CASE j.status WHEN 'pending' THEN 0 WHEN 'failed' THEN 1 ELSE 2 END, j.queued_at, j.character_id
    LIMIT v_limit
    FOR UPDATE OF j SKIP LOCKED
  ),
  claimed AS (
    UPDATE public.encounter_schedule_generation_jobs j
    SET status = 'processing',
        lease_token = v_lease,
        lease_expires_at = v_now + interval '20 minutes',
        lease_generation = j.lease_generation + 1,
        attempt_count = j.attempt_count + 1,
        updated_at = v_now
    FROM candidates c
    WHERE j.character_id = c.character_id
    RETURNING j.character_id
  )
  SELECT pg_catalog.array_agg(character_id ORDER BY character_id)
  INTO v_ids
  FROM claimed;

  IF COALESCE(pg_catalog.cardinality(v_ids), 0) = 0 THEN
    RETURN pg_catalog.jsonb_build_object('status', 'no_pending_jobs', 'pending_character_count', v_pending_count);
  END IF;

  INSERT INTO public.encounter_schedule_batch_runs (
    lease_token, status, character_ids, actor_user_id, is_manual, started_at, updated_at
  ) VALUES (
    v_lease, 'processing', v_ids, p_actor_user_id, p_force IS TRUE, v_now, v_now
  )
  RETURNING id INTO v_batch;

  SELECT pg_catalog.jsonb_agg(
    public.encounter_schedule_source_payload(x.character_id) ||
    pg_catalog.jsonb_build_object('worldview_review_decision', j.worldview_review_decision)
  )
  INTO v_characters
  FROM pg_catalog.unnest(v_ids) AS x(character_id)
  JOIN public.encounter_schedule_generation_jobs j ON j.character_id = x.character_id;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'claimed',
    'batch_id', v_batch,
    'lease_token', v_lease,
    'characters', COALESCE(v_characters, '[]'::jsonb)
  );
END;
$function$;

COMMENT ON FUNCTION public.claim_encounter_schedule_batch(integer, boolean, uuid) IS
  'Claims schedule jobs. Manual claims are strictly scoped to p_actor_user_id in both preflight counts and candidate selection.';
