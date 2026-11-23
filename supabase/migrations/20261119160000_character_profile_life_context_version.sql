-- Version the combined v1.1 Character AI Profile and include saved occupation as a source.
-- Legacy profiles are refreshed only after an AI-relevant source change.
-- The caller passes a deterministic source-change decision. This migration
-- does not insert jobs, invoke AI, or activate any Worker/Cron schedule.

BEGIN;

-- Include the author's saved occupation in the allowlisted source hash and model input.
CREATE OR REPLACE FUNCTION public.character_profile_source_payload(
  p_character_id uuid,
  p_author_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $profile_source$
DECLARE
  v_payload jsonb;
BEGIN
  SELECT jsonb_build_object(
    'characters.intro', COALESCE(c.intro, ''),
    'characters.race', COALESCE(c.race, ''),
    'characters.style', COALESCE(c.style, ''),
    'character_private_info.private_info', COALESCE(pi.private_info, ''),
    'character_private_info.personality_profile.coreTraits', to_jsonb(COALESCE(pi.personality_profile ->> 'coreTraits', '')),
    'character_private_info.personality_profile.values', to_jsonb(COALESCE(pi.personality_profile ->> 'values', '')),
    'character_private_info.personality_profile.speechStyle', to_jsonb(COALESCE(pi.personality_profile ->> 'speechStyle', '')),
    'character_private_info.personality_profile.behaviorRules', to_jsonb(COALESCE(pi.personality_profile ->> 'behaviorRules', '')),
    'character_private_info.personality_profile.likes', to_jsonb(COALESCE(pi.personality_profile ->> 'likes', '')),
    'character_private_info.personality_profile.dislikes', to_jsonb(COALESCE(pi.personality_profile ->> 'dislikes', '')),
    'character_private_info.personality_profile.boundaries', to_jsonb(COALESCE(pi.personality_profile ->> 'boundaries', '')),
    'character_private_info.personality_profile.relationshipPacing', to_jsonb(COALESCE(pi.personality_profile ->> 'relationshipPacing', '')),
    'character_private_info.personality_profile.occupation', to_jsonb(COALESCE(pi.personality_profile ->> 'occupation', ''))
  )
  INTO v_payload
  FROM public.characters c
  LEFT JOIN public.character_private_info pi
    ON pi.character_id = c.id AND pi.author_id = c.author_id
  WHERE c.id = p_character_id
    AND c.author_id = p_author_id
    AND c.deleted_at IS NULL;

  IF v_payload IS NOT NULL AND octet_length(v_payload::text) > 65536 THEN
    RETURN jsonb_build_object('__profile_source_error', 'source_payload_too_large');
  END IF;
  RETURN v_payload;
END;
$profile_source$;

REVOKE ALL ON FUNCTION public.character_profile_source_payload(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.character_profile_source_payload(uuid, uuid)
  TO service_role;

-- No Worker is allowed to be in-flight while source hashes are migrated.
LOCK TABLE public.character_profile_organization_jobs IN SHARE ROW EXCLUSIVE MODE;
-- Re-hash existing queued rows against the expanded allowlist without changing
-- their status, attempts, or availability. This prevents an avoidable paid
-- generation followed by a stale-source rejection on the next manual run.
DO $profile_hash_preflight$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.character_profile_organization_jobs
    WHERE status = 'processing'
  ) THEN
    RAISE EXCEPTION 'character_profile_worker_active_retry_migration';
  END IF;
END;
$profile_hash_preflight$;

WITH refreshed AS (
  SELECT
    j.character_id,
    encode(extensions.digest(convert_to(source_payload.payload::text, 'UTF8'), 'sha256'), 'hex') AS source_hash
  FROM public.character_profile_organization_jobs j
  CROSS JOIN LATERAL (
    SELECT public.character_profile_source_payload(j.character_id, j.author_id) AS payload
  ) source_payload
  WHERE source_payload.payload IS NOT NULL
)
UPDATE public.character_profile_organization_jobs j
SET source_hash = refreshed.source_hash,
    updated_at = now()
FROM refreshed
WHERE refreshed.character_id = j.character_id
  AND j.source_hash IS DISTINCT FROM refreshed.source_hash;

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
     OR (COALESCE(p_source_changed, true) IS TRUE
         AND public.character_profile_organization_jobs.status = 'failed')
     OR (
       public.character_profile_organization_jobs.status = 'completed'
       AND COALESCE(p_source_changed, true) IS TRUE
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
AS $queue_wrapper$
BEGIN
  RETURN public.enqueue_character_profile_organization(p_character_id, true);
END;
$queue_wrapper$;

REVOKE ALL ON FUNCTION public.enqueue_character_profile_organization(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enqueue_character_profile_organization(uuid)
  TO authenticated;

COMMIT;
