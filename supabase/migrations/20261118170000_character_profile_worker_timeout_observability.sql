-- Widen the Character AI Profile worker safety lease for measurement.
-- Additive source migration only; not applied to hosted Supabase here.
ALTER TABLE public.character_profile_organization_usage
  ADD COLUMN IF NOT EXISTS duration_ms integer
  CHECK (duration_ms IS NULL OR duration_ms >= 0);

COMMENT ON COLUMN public.character_profile_organization_usage.duration_ms IS
  'Provider request-to-validated-response duration in milliseconds; metadata only.';

CREATE OR REPLACE FUNCTION public.claim_character_profile_organization_jobs(
  p_limit integer DEFAULT 1
)
RETURNS TABLE (
  character_id uuid, author_id uuid, source_hash text, lease_token uuid,
  lease_generation bigint, lease_expires_at timestamptz, source_payload jsonb
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 5 THEN
    RAISE EXCEPTION 'invalid_claim_limit' USING ERRCODE = '22023';
  END IF;
  IF NOT pg_try_advisory_xact_lock(748293, 20261107) THEN RETURN; END IF;

  UPDATE public.character_profile_organization_jobs AS expired_job
  SET status = 'failed', lease_token = NULL, lease_expires_at = NULL,
      lease_source_hash = NULL,
      last_error_code = 'worker_lease_expired_manual_retry', updated_at = now()
  WHERE expired_job.status = 'processing' AND expired_job.lease_expires_at <= now();

  IF EXISTS (
    SELECT 1 FROM public.character_profile_organization_jobs AS active_job
    WHERE active_job.status = 'processing' AND active_job.lease_expires_at > now()
  ) THEN RETURN; END IF;

  RETURN QUERY
  WITH candidates AS (
    SELECT j.character_id FROM public.character_profile_organization_jobs j
    WHERE j.status = 'pending' AND j.available_at <= now()
    ORDER BY j.available_at, j.created_at FOR UPDATE SKIP LOCKED LIMIT p_limit
  ), claimed AS (
    UPDATE public.character_profile_organization_jobs j
    SET status = 'processing', lease_token = gen_random_uuid(),
        lease_generation = j.lease_generation + 1,
        -- Ten-minute recovery lease, not a ten-minute provider request timeout.
        lease_expires_at = now() + interval '10 minutes',
        lease_source_hash = j.source_hash, updated_at = now()
    FROM candidates c WHERE j.character_id = c.character_id
    RETURNING j.character_id, j.author_id, j.source_hash,
      j.lease_token, j.lease_generation, j.lease_expires_at
  )
  SELECT c.character_id, c.author_id, c.source_hash, c.lease_token,
    c.lease_generation, c.lease_expires_at,
    public.character_profile_source_payload(c.character_id, c.author_id)
  FROM claimed c;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_character_profile_organization_jobs(integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_character_profile_organization_jobs(integer)
  TO service_role;
