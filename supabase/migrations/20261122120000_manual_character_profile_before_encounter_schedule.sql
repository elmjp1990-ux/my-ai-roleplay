-- Shared selector used by the Profile status endpoint, Profile claim, and
-- schedule preflight so all three agree on the exact next eligible character.
CREATE OR REPLACE FUNCTION public.get_next_encounter_schedule_character_for_author(
  p_author_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $
  SELECT jsonb_build_object(
    'character_id', j.character_id,
    'character_name', c.name
  )
  FROM public.encounter_schedule_generation_jobs j
  JOIN public.characters c ON c.id = j.character_id
  WHERE j.author_id = p_author_id
    AND j.status = 'pending'
    AND c.visibility = 'public'
    AND c.review_status = 'approved'
    AND c.rights_confirmed IS TRUE
    AND c.deleted_at IS NULL
  ORDER BY j.queued_at, j.character_id
  LIMIT 1;
$;

REVOKE ALL ON FUNCTION public.get_next_encounter_schedule_character_for_author(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_next_encounter_schedule_character_for_author(uuid)
  TO service_role;

-- Manual, author-scoped Profile generation for the next pending Encounter schedule role.
-- This RPC is service-role only; the Edge Function authenticates the author first.
CREATE OR REPLACE FUNCTION public.claim_next_encounter_character_profile_job(
  p_author_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_character_id uuid;
  v_character_name text;
  v_payload jsonb;
  v_hash text;
  v_profile jsonb;
  v_job public.character_profile_organization_jobs%ROWTYPE;
  v_lease uuid;
BEGIN
  IF COALESCE(auth.jwt() ->> 'role', '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF p_author_id IS NULL THEN
    RAISE EXCEPTION 'author_id_required' USING ERRCODE = '22023';
  END IF;

  -- Share the same serialization lock as the existing global worker. This keeps
  -- manual and future scheduled Profile generation from claiming concurrently.
  IF NOT pg_try_advisory_xact_lock(748293, 20261107) THEN
    RETURN jsonb_build_object('status', 'busy');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.character_profile_organization_jobs j
    WHERE j.status = 'processing'
      AND j.lease_expires_at > now()
  ) THEN
    RETURN jsonb_build_object('status', 'busy');
  END IF;

  -- The Profile step always targets the exact next pending public character
  -- that the manual Encounter schedule step will claim.
  v_payload := public.get_next_encounter_schedule_character_for_author(p_author_id);
  IF v_payload IS NOT NULL THEN
    v_character_id := (v_payload ->> 'character_id')::uuid;
    v_character_name := COALESCE(v_payload ->> 'character_name', '角色');
  END IF;

  IF v_character_id IS NULL THEN
    RETURN jsonb_build_object('status', 'no_pending_schedule_jobs');
  END IF;

  v_payload := public.character_profile_source_payload(v_character_id, p_author_id);
  IF v_payload IS NULL THEN
    RETURN jsonb_build_object('status', 'profile_source_unavailable');
  END IF;
  v_hash := encode(extensions.digest(convert_to(v_payload::text, 'UTF8'), 'sha256'), 'hex');

  SELECT p.profile INTO v_profile
  FROM public.character_profile_organization p
  WHERE p.character_id = v_character_id
    AND p.author_id = p_author_id
    AND p.source_hash = v_hash;

  IF v_profile IS NOT NULL
     AND v_profile ->> 'schema_version' = '1.1'
     AND CASE
       WHEN jsonb_typeof(v_profile -> 'life_context') = 'object' THEN
         (v_profile -> 'life_context') ?& ARRAY[
           'work_environment', 'residence_environment', 'daily_routines',
           'interests_and_leisure', 'social_circles', 'recurring_places',
           'environmental_constraints'
         ]
         AND (SELECT count(*) FROM jsonb_object_keys(v_profile -> 'life_context')) = 7
       ELSE false
     END THEN
    UPDATE public.character_profile_organization_jobs
    SET status = 'completed',
        source_hash = v_hash,
        lease_token = NULL,
        lease_expires_at = NULL,
        lease_source_hash = NULL,
        last_error_code = NULL,
        completed_at = COALESCE(completed_at, now()),
        updated_at = now()
    WHERE character_id = v_character_id
      AND author_id = p_author_id;
    RETURN jsonb_build_object(
      'status', 'already_completed',
      'character_id', v_character_id,
      'character_name', v_character_name,
      'profile', v_profile
    );
  END IF;

  INSERT INTO public.character_profile_organization_jobs (
    character_id, author_id, source_hash, status, attempt_count,
    available_at, lease_token, lease_expires_at, lease_source_hash,
    last_error_code, lease_generation, completed_at, updated_at
  ) VALUES (
    v_character_id, p_author_id, v_hash, 'pending', 0,
    now(), NULL, NULL, NULL, NULL, 0, NULL, now()
  )
  ON CONFLICT (character_id) DO NOTHING;

  SELECT * INTO v_job
  FROM public.character_profile_organization_jobs
  WHERE character_id = v_character_id
    AND author_id = p_author_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'profile_job_unavailable');
  END IF;

  IF v_job.source_hash IS DISTINCT FROM v_hash THEN
    UPDATE public.character_profile_organization_jobs
    SET source_hash = v_hash,
        status = 'pending',
        attempt_count = 0,
        available_at = now(),
        lease_token = NULL,
        lease_expires_at = NULL,
        lease_source_hash = NULL,
        last_error_code = NULL,
        lease_generation = lease_generation + 1,
        completed_at = NULL,
        updated_at = now()
    WHERE character_id = v_character_id;
    SELECT * INTO v_job
    FROM public.character_profile_organization_jobs
    WHERE character_id = v_character_id
    FOR UPDATE;
  END IF;

  IF v_job.status = 'processing' AND v_job.lease_expires_at > now() THEN
    RETURN jsonb_build_object('status', 'busy');
  END IF;

  IF v_job.status = 'completed' THEN
    UPDATE public.character_profile_organization_jobs
    SET status = 'pending',
        attempt_count = 0,
        available_at = now(),
        lease_token = NULL,
        lease_expires_at = NULL,
        lease_source_hash = NULL,
        last_error_code = 'profile_schema_refresh_required',
        completed_at = NULL,
        updated_at = now()
    WHERE character_id = v_character_id;
    SELECT * INTO v_job
    FROM public.character_profile_organization_jobs
    WHERE character_id = v_character_id
    FOR UPDATE;
  END IF;

  -- Ambiguous/terminal failures are not retried by opening the panel or refreshing.
  -- A separate explicit recovery action can be added after reviewing the audit row.
  IF v_job.status = 'failed' THEN
    RETURN jsonb_build_object(
      'status', 'failed',
      'character_id', v_character_id,
      'character_name', v_character_name,
      'error_code', v_job.last_error_code
    );
  END IF;

  IF v_job.status = 'processing' AND v_job.lease_expires_at <= now() THEN
    UPDATE public.character_profile_organization_jobs
    SET status = 'failed',
        lease_token = NULL,
        lease_expires_at = NULL,
        lease_source_hash = NULL,
        last_error_code = 'worker_lease_expired_manual_retry',
        updated_at = now()
    WHERE character_id = v_character_id;
    RETURN jsonb_build_object(
      'status', 'failed',
      'character_id', v_character_id,
      'character_name', v_character_name,
      'error_code', 'worker_lease_expired_manual_retry'
    );
  END IF;

  IF v_job.status <> 'pending' THEN
    RETURN jsonb_build_object('status', 'not_ready', 'job_status', v_job.status);
  END IF;

  IF v_job.available_at > now() THEN
    RETURN jsonb_build_object('status', 'waiting', 'available_at', v_job.available_at);
  END IF;

  UPDATE public.character_profile_organization_jobs
  SET status = 'processing',
      lease_token = gen_random_uuid(),
      lease_generation = lease_generation + 1,
      lease_expires_at = now() + interval '3 minutes',
      lease_source_hash = v_hash,
      updated_at = now()
  WHERE character_id = v_character_id
  RETURNING * INTO v_job;

  v_lease := v_job.lease_token;
  RETURN jsonb_build_object(
    'status', 'claimed',
    'character_id', v_character_id,
    'character_name', v_character_name,
    'item', jsonb_build_object(
      'character_id', v_character_id,
      'author_id', p_author_id,
      'source_hash', v_hash,
      'lease_token', v_lease,
      'lease_generation', v_job.lease_generation,
      'lease_expires_at', v_job.lease_expires_at,
      'source_payload', v_payload
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.claim_next_encounter_character_profile_job(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_next_encounter_character_profile_job(uuid)
  TO service_role;

COMMENT ON FUNCTION public.claim_next_encounter_character_profile_job(uuid) IS
  'Manual two-step Encounter flow: claim the next pending schedule character Profile for one authenticated author only. No cross-author queue claim and no automatic retry of terminal failures.';
