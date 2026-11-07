-- Character AI Profile organization queue and backend-only derived profile storage.
-- This migration is intentionally additive. It is committed to the PR branch only;
-- it is NOT applied to any hosted Supabase project by this change.

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE TABLE IF NOT EXISTS public.character_profile_organization_jobs (
  character_id uuid PRIMARY KEY REFERENCES public.characters(id) ON DELETE CASCADE,
  author_id uuid NOT NULL,
  source_hash text NOT NULL CHECK (source_hash ~ '^[0-9a-f]{64}$'),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  available_at timestamptz NOT NULL DEFAULT now(),
  lease_token uuid,
  lease_generation bigint NOT NULL DEFAULT 0 CHECK (lease_generation >= 0),
  lease_expires_at timestamptz,
  lease_source_hash text CHECK (lease_source_hash IS NULL OR lease_source_hash ~ '^[0-9a-f]{64} timestamptz NOT NULL DEFAULT now(),
  last_error_code text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  CHECK (
    (status = 'processing' AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL
      AND lease_source_hash IS NOT NULL)
    OR status <> 'processing'
  )
);

CREATE INDEX IF NOT EXISTS character_profile_jobs_claim_idx
  ON public.character_profile_organization_jobs (available_at, created_at)
  WHERE status IN ('pending', 'processing');

CREATE TABLE IF NOT EXISTS public.character_profile_organization_usage (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  character_id uuid REFERENCES public.characters(id) ON DELETE SET NULL,
  author_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  source_hash text NOT NULL CHECK (source_hash ~ '^[0-9a-f]{64}$'),
  model text NOT NULL CHECK (model = 'deepseek/deepseek-v4-flash-20260423'),
  provider text CHECK (provider IS NULL OR char_length(provider) <= 100),
  gateway_request_id text CHECK (gateway_request_id IS NULL OR char_length(gateway_request_id) <= 128),
  prompt_tokens integer CHECK (prompt_tokens IS NULL OR prompt_tokens >= 0),
  completion_tokens integer CHECK (completion_tokens IS NULL OR completion_tokens >= 0),
  total_tokens integer CHECK (total_tokens IS NULL OR total_tokens >= 0),
  cost_usd numeric(20,12) CHECK (cost_usd IS NULL OR cost_usd >= 0),
  status text NOT NULL CHECK (status IN ('generated', 'failed')),
  error_code text CHECK (error_code IS NULL OR char_length(error_code) <= 100),
  created_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS character_profile_usage_author_created_idx
  ON public.character_profile_organization_usage (author_id, created_at DESC);

ALTER TABLE public.character_profile_organization_usage ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.character_profile_organization_usage FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.character_profile_organization_usage TO service_role;
COMMENT ON TABLE public.character_profile_organization_usage IS
  'Service-role-only token/cost ledger for character Profile organization. Stores usage metadata only, never source text or prompts.';

CREATE TABLE IF NOT EXISTS public.character_profile_organization (
  character_id uuid PRIMARY KEY REFERENCES public.characters(id) ON DELETE CASCADE,
  author_id uuid NOT NULL,
  source_hash text NOT NULL CHECK (source_hash ~ '^[0-9a-f]{64}$'),
  model text NOT NULL CHECK (model = 'deepseek/deepseek-v4-flash-20260423'),
  profile jsonb NOT NULL CHECK (jsonb_typeof(profile) = 'object'),
  generated_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.character_profile_organization_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.character_profile_organization ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.character_profile_organization_jobs FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.character_profile_organization FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.character_profile_organization_jobs TO service_role;
GRANT ALL ON public.character_profile_organization TO service_role;
-- Return only the exact allowlisted creator sources. This helper is callable only
-- from the security-definer RPCs below and service_role.
CREATE OR REPLACE FUNCTION public.character_profile_source_payload(
  p_character_id uuid,
  p_author_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_payload jsonb;
BEGIN
  SELECT jsonb_build_object(
    'characters.intro', COALESCE(c.intro, ''),
    'characters.race', COALESCE(c.race, ''),
    'characters.style', COALESCE(c.style, ''),
    'character_private_info.private_info', COALESCE(pi.private_info, ''),
    'character_private_info.personality_profile.coreTraits', COALESCE(pi.personality_profile -> 'coreTraits', 'null'::jsonb),
    'character_private_info.personality_profile.values', COALESCE(pi.personality_profile -> 'values', 'null'::jsonb),
    'character_private_info.personality_profile.speechStyle', COALESCE(pi.personality_profile -> 'speechStyle', 'null'::jsonb),
    'character_private_info.personality_profile.behaviorRules', COALESCE(pi.personality_profile -> 'behaviorRules', 'null'::jsonb),
    'character_private_info.personality_profile.likes', COALESCE(pi.personality_profile -> 'likes', 'null'::jsonb),
    'character_private_info.personality_profile.dislikes', COALESCE(pi.personality_profile -> 'dislikes', 'null'::jsonb),
    'character_private_info.personality_profile.boundaries', COALESCE(pi.personality_profile -> 'boundaries', 'null'::jsonb),
    'character_private_info.personality_profile.relationshipPacing', COALESCE(pi.personality_profile -> 'relationshipPacing', 'null'::jsonb)
  )
  INTO v_payload
  FROM public.characters c
  LEFT JOIN public.character_private_info pi
    ON pi.character_id = c.id AND pi.author_id = c.author_id
  WHERE c.id = p_character_id
    AND c.author_id = p_author_id
    AND c.deleted_at IS NULL;

  RETURN v_payload;
END;
$$;

REVOKE ALL ON FUNCTION public.character_profile_source_payload(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.character_profile_source_payload(uuid, uuid)
  TO service_role;

CREATE OR REPLACE FUNCTION public.enqueue_character_profile_organization(
  p_character_id uuid
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
    -- If a Worker is already generating the previous source, keep its lease
    -- active and let completion detect the changed source and queue the latest
    -- payload. This prevents a second Worker from starting concurrently.
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
  WHERE public.character_profile_organization_jobs.source_hash IS DISTINCT FROM EXCLUDED.source_hash
     OR public.character_profile_organization_jobs.author_id IS DISTINCT FROM EXCLUDED.author_id
     OR public.character_profile_organization_jobs.status = 'failed'
  RETURNING * INTO v_job;

  -- Same source already pending/processing/completed: preserve retry timing and
  -- lease. Changed source during processing is coalesced behind the active lease;
  -- completion will queue only the latest source after the current call finishes.
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

REVOKE ALL ON FUNCTION public.enqueue_character_profile_organization(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enqueue_character_profile_organization(uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.claim_character_profile_organization_jobs(
  p_limit integer DEFAULT 1
)
RETURNS TABLE (
  character_id uuid,
  author_id uuid,
  source_hash text,
  lease_token uuid,
  lease_generation bigint,
  lease_expires_at timestamptz,
  source_payload jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 5 THEN
    RAISE EXCEPTION 'invalid_claim_limit' USING ERRCODE = '22023';
  END IF;

  -- Serialize claim transactions globally. The transaction lock closes the
  -- race where two cron invocations could both observe an empty active queue.
  IF NOT pg_try_advisory_xact_lock(748293, 20261107) THEN
    RETURN;
  END IF;

  -- Keep profile organization serial by default to control model spend and avoid
  -- overlapping generations for different roles. Expired leases remain reclaimable.
  IF EXISTS (
    SELECT 1 FROM public.character_profile_organization_jobs AS active_job
    WHERE active_job.status = 'processing' AND active_job.lease_expires_at > now()
  ) THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH candidates AS (
    SELECT j.character_id
    FROM public.character_profile_organization_jobs j
    WHERE (
      (j.status = 'pending' AND j.available_at <= now())
      OR (j.status = 'processing' AND j.lease_expires_at < now())
    )
    ORDER BY j.available_at, j.created_at
    FOR UPDATE SKIP LOCKED
    LIMIT p_limit
  ), claimed AS (
    UPDATE public.character_profile_organization_jobs j
    SET status = 'processing',
        lease_token = gen_random_uuid(),
        lease_generation = j.lease_generation + 1,
        lease_expires_at = now() + interval '3 minutes',
        lease_source_hash = j.source_hash,
        updated_at = now()
    FROM candidates c
    WHERE j.character_id = c.character_id
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

CREATE OR REPLACE FUNCTION public.complete_character_profile_organization_job(
  p_character_id uuid,
  p_lease_token uuid,
  p_lease_generation bigint,
  p_source_hash text,
  p_profile jsonb
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_job public.character_profile_organization_jobs%ROWTYPE;
  v_current_payload jsonb;
  v_current_hash text;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_profile) <> 'object' OR p_source_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid_profile_payload' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_job
  FROM public.character_profile_organization_jobs
  WHERE character_id = p_character_id
  FOR UPDATE;

  IF NOT FOUND OR v_job.status <> 'processing'
     OR v_job.lease_token IS DISTINCT FROM p_lease_token
     OR v_job.lease_generation IS DISTINCT FROM p_lease_generation
     OR v_job.lease_expires_at <= now()
     OR v_job.lease_source_hash IS DISTINCT FROM p_source_hash THEN
    RETURN 'lease_lost';
  END IF;

  v_current_payload := public.character_profile_source_payload(v_job.character_id, v_job.author_id);
  IF v_current_payload IS NULL THEN
    DELETE FROM public.character_profile_organization_jobs WHERE character_id = p_character_id;
    DELETE FROM public.character_profile_organization WHERE character_id = p_character_id;
    RETURN 'character_deleted';
  END IF;
  v_current_hash := encode(extensions.digest(convert_to(v_current_payload::text, 'UTF8'), 'sha256'), 'hex');

  IF v_current_hash IS DISTINCT FROM p_source_hash THEN
    UPDATE public.character_profile_organization_jobs
    SET source_hash = v_current_hash, status = 'pending', attempt_count = 0,
        available_at = now(), lease_token = NULL, lease_expires_at = NULL,
        lease_source_hash = NULL, last_error_code = 'stale_source',
        lease_generation = lease_generation + 1,
        updated_at = now()
    WHERE character_id = p_character_id;
    RETURN 'stale_source';
  END IF;

  INSERT INTO public.character_profile_organization (
    character_id, author_id, source_hash, model, profile, generated_at, updated_at
  ) VALUES (
    v_job.character_id, v_job.author_id, p_source_hash,
    'deepseek/deepseek-v4-flash-20260423', p_profile, now(), now()
  )
  ON CONFLICT (character_id) DO UPDATE SET
    author_id = EXCLUDED.author_id,
    source_hash = EXCLUDED.source_hash,
    model = EXCLUDED.model,
    profile = EXCLUDED.profile,
    generated_at = now(),
    updated_at = now();

  UPDATE public.character_profile_organization_jobs
  SET source_hash = p_source_hash, status = 'completed',
      lease_token = NULL, lease_expires_at = NULL, lease_source_hash = NULL,
      last_error_code = NULL, completed_at = now(), updated_at = now()
  WHERE character_id = p_character_id;

  RETURN 'completed';
END;
$$;

REVOKE ALL ON FUNCTION public.complete_character_profile_organization_job(uuid, uuid, bigint, text, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_character_profile_organization_job(uuid, uuid, bigint, text, jsonb)
  TO service_role;

CREATE OR REPLACE FUNCTION public.fail_character_profile_organization_job(
  p_character_id uuid,
  p_lease_token uuid,
  p_lease_generation bigint,
  p_error_code text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_job public.character_profile_organization_jobs%ROWTYPE;
  v_attempt integer;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_job
  FROM public.character_profile_organization_jobs
  WHERE character_id = p_character_id
  FOR UPDATE;

  IF NOT FOUND OR v_job.status <> 'processing'
     OR v_job.lease_token IS DISTINCT FROM p_lease_token
     OR v_job.lease_generation IS DISTINCT FROM p_lease_generation
     OR v_job.lease_expires_at <= now() THEN
    RETURN 'lease_lost';
  END IF;

  v_attempt := v_job.attempt_count + 1;
  UPDATE public.character_profile_organization_jobs
  SET attempt_count = v_attempt,
      status = CASE WHEN v_attempt >= 5 THEN 'failed' ELSE 'pending' END,
      available_at = now() + make_interval(secs => LEAST(3600, 30 * power(2, v_attempt - 1))::integer),
      lease_token = NULL,
      lease_expires_at = NULL,
      lease_source_hash = NULL,
      last_error_code = left(regexp_replace(COALESCE(p_error_code, 'worker_failed'), '[^a-zA-Z0-9:_-]', '', 'g'), 100),
      updated_at = now()
  WHERE character_id = p_character_id;

  RETURN CASE WHEN v_attempt >= 5 THEN 'failed' ELSE 'retry_scheduled' END;
END;
$$;

REVOKE ALL ON FUNCTION public.fail_character_profile_organization_job(uuid, uuid, bigint, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fail_character_profile_organization_job(uuid, uuid, bigint, text)
  TO service_role;

CREATE OR REPLACE FUNCTION public.get_character_ai_profile_for_chat(
  p_character_id uuid,
  p_author_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_payload jsonb;
  v_hash text;
  v_profile jsonb;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  v_payload := public.character_profile_source_payload(p_character_id, p_author_id);
  IF v_payload IS NULL THEN RETURN NULL; END IF;
  v_hash := encode(extensions.digest(convert_to(v_payload::text, 'UTF8'), 'sha256'), 'hex');

  SELECT p.profile INTO v_profile
  FROM public.character_profile_organization p
  WHERE p.character_id = p_character_id
    AND p.author_id = p_author_id
    AND p.source_hash = v_hash;

  RETURN v_profile;
END;
$$;

REVOKE ALL ON FUNCTION public.get_character_ai_profile_for_chat(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_character_ai_profile_for_chat(uuid, uuid)
  TO service_role;

-- Soft-deleting a character invalidates pending work and removes the backend-only
-- derived profile immediately. Hard deletes are also covered by the FK cascades.
CREATE OR REPLACE FUNCTION public.cleanup_character_profile_organization_on_soft_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS DISTINCT FROM NEW.deleted_at THEN
    DELETE FROM public.character_profile_organization_jobs WHERE character_id = NEW.id;
    DELETE FROM public.character_profile_organization WHERE character_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.cleanup_character_profile_organization_on_soft_delete()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS character_profile_organization_soft_delete_cleanup
  ON public.characters;
CREATE TRIGGER character_profile_organization_soft_delete_cleanup
AFTER UPDATE OF deleted_at ON public.characters
FOR EACH ROW
WHEN (OLD.deleted_at IS DISTINCT FROM NEW.deleted_at AND NEW.deleted_at IS NOT NULL)
EXECUTE FUNCTION public.cleanup_character_profile_organization_on_soft_delete();
