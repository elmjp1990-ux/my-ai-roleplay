-- Requeue legacy Character AI Profiles once so the combined v1.1 profile
-- (including structured life_context) is generated from the current source.
-- The caller passes a deterministic source-change decision. This migration
-- does not insert jobs, invoke AI, or activate any Worker/Cron schedule.

BEGIN;

CREATE OR REPLACE FUNCTION public.enqueue_character_profile_organization(
  p_character_id uuid,
  p_source_changed boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_author_id uuid := auth.uid();
  v_payload jsonb;
  v_hash text;
  v_job public.character_profile_organization_jobs%ROWTYPE;
BEGIN
  IF v_author_id IS NULL THEN
    RAISE EXCEPTION 'authentication_required' USING ERRCODE = '42501';
  END IF;

  v_payload := public.character_profile_source_payload(p_character_id, v_author_id);
  IF v_payload IS NULL THEN
    RAISE EXCEPTION 'character_not_owned_or_deleted' USING ERRCODE = '42501';
  END IF;

  v_hash := encode(extensions.digest(convert_to(v_payload::text, 'UTF8'), 'sha256'), 'hex');

  INSERT INTO public.character_profile_organization_jobs (
    character_id, author_id, source_hash, status, attempt_count,
    available_at, lease_token, lease_expires_at, last_error_code,
    lease_generation, completed_at, updated_at
  ) VALUES (
    p_character_id, v_author_id, v_hash, 'pending', 0,
    now(), NULL, NULL, NULL, 1, NULL, now()
  )
  ON CONFLICT (character_id) DO UPDATE SET
    author_id = EXCLUDED.author_id,
    source_hash = EXCLUDED.source_hash,
    status = CASE
      WHEN public.character_profile_organization_jobs.status = 'processing'
       AND public.character_profile_organization_jobs.lease_expires_at > now()
      THEN 'processing' ELSE 'pending' END,
    attempt_count = 0,
    available_at = CASE
      WHEN public.character_profile_organization_jobs.status = 'processing'
       AND public.character_profile_organization_jobs.lease_expires_at > now()
      THEN public.character_profile_organization_jobs.available_at ELSE now() END,
    lease_token = CASE
      WHEN public.character_profile_organization_jobs.status = 'processing'
       AND public.character_profile_organization_jobs.lease_expires_at > now()
      THEN public.character_profile_organization_jobs.lease_token ELSE NULL END,
    lease_expires_at = CASE
      WHEN public.character_profile_organization_jobs.status = 'processing'
       AND public.character_profile_organization_jobs.lease_expires_at > now()
      THEN public.character_profile_organization_jobs.lease_expires_at ELSE NULL END,
    lease_source_hash = CASE
      WHEN public.character_profile_organization_jobs.status = 'processing'
       AND public.character_profile_organization_jobs.lease_expires_at > now()
      THEN public.character_profile_organization_jobs.lease_source_hash ELSE NULL END,
    last_error_code = NULL,
    lease_generation = public.character_profile_organization_jobs.lease_generation
      + CASE
          WHEN public.character_profile_organization_jobs.status = 'processing'
           AND public.character_profile_organization_jobs.lease_expires_at > now()
          THEN 0 ELSE 1
        END,
    completed_at = NULL,
    updated_at = now()
  WHERE (COALESCE(p_source_changed, true) IS TRUE
         AND public.character_profile_organization_jobs.source_hash IS DISTINCT FROM EXCLUDED.source_hash)
     OR public.character_profile_organization_jobs.author_id IS DISTINCT FROM EXCLUDED.author_id
     OR public.character_profile_organization_jobs.status = 'failed'
     OR (
       public.character_profile_organization_jobs.status = 'completed'
       AND NOT EXISTS (
         SELECT 1
         FROM public.character_profile_organization p
         WHERE p.character_id = EXCLUDED.character_id
           AND p.author_id = EXCLUDED.author_id
           AND p.source_hash = EXCLUDED.source_hash
           AND p.profile->>'schema_version' = '1.1'
           AND p.profile ? 'life_context'
       )
     )
  RETURNING * INTO v_job;

  IF NOT FOUND THEN
    SELECT * INTO v_job
    FROM public.character_profile_organization_jobs
    WHERE character_id = p_character_id
    FOR UPDATE;
  END IF;

  RETURN jsonb_build_object(
    'status', v_job.status,
    'source_hash', v_job.source_hash,
    'lease_generation', v_job.lease_generation,
    'reused_existing_job', v_job.source_hash = v_hash
      AND v_job.status IN ('pending', 'processing', 'completed')
  );
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_character_profile_organization(uuid, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enqueue_character_profile_organization(uuid, boolean)
  TO authenticated;

-- Preserve compatibility for older clients that still call the one-argument RPC.
CREATE OR REPLACE FUNCTION public.enqueue_character_profile_organization(
  p_character_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $
BEGIN
  RETURN public.enqueue_character_profile_organization(p_character_id, true);
END;
$;

REVOKE ALL ON FUNCTION public.enqueue_character_profile_organization(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enqueue_character_profile_organization(uuid)
  TO authenticated;

COMMIT;
