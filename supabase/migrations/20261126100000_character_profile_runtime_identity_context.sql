-- Supply current name/gender/age to the profile organizer without making routine identity edits trigger paid regeneration.
BEGIN;
CREATE OR REPLACE FUNCTION public.character_profile_source_hash_payload(p_payload jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
  SELECT p_payload - ARRAY['characters.name', 'characters.gender', 'characters.age']::text[];
$$;
REVOKE ALL ON FUNCTION public.character_profile_source_hash_payload(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.character_profile_source_hash_payload(jsonb) TO service_role;

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
    'characters.name', COALESCE(c.name, ''),
    'characters.gender', COALESCE(c.gender, ''),
    'characters.age', COALESCE(c.age::text, ''),
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
REVOKE ALL ON FUNCTION public.character_profile_source_payload(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.character_profile_source_payload(uuid, uuid) TO service_role;

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

  v_hash := encode(extensions.digest(convert_to(public.character_profile_source_hash_payload(v_payload)::text, 'UTF8'), 'sha256'), 'hex');

  -- A save that changed only runtime identity facts must not create a new job.
  -- Preserve any already-existing job unchanged; only a changed profile source
  -- or a changed owner may proceed to the upsert below.
  IF p_source_changed IS NOT TRUE THEN
    SELECT * INTO v_job
    FROM public.character_profile_organization_jobs
    WHERE character_id = p_character_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'status', 'not_enqueued',
        'source_hash', v_hash,
        'lease_generation', NULL,
        'reused_existing_job', false
      );
    END IF;

    IF v_job.author_id = v_author_id THEN
      RETURN jsonb_build_object(
        'status', v_job.status,
        'source_hash', v_job.source_hash,
        'lease_generation', v_job.lease_generation,
        'reused_existing_job', v_job.source_hash = v_hash
          AND v_job.status IN ('pending', 'processing', 'completed')
      );
    END IF;
  END IF;

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
REVOKE ALL ON FUNCTION public.enqueue_character_profile_organization(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enqueue_character_profile_organization(uuid, boolean) TO authenticated;

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
  IF jsonb_typeof(p_profile) <> 'object'
     OR octet_length(p_profile::text) > 49152
     OR p_source_hash IS NULL
     OR char_length(p_source_hash) <> 64
     OR p_source_hash ~ '[^0-9a-f]' THEN
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
  v_current_hash := encode(extensions.digest(convert_to(public.character_profile_source_hash_payload(v_current_payload)::text, 'UTF8'), 'sha256'), 'hex');

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
REVOKE ALL ON FUNCTION public.complete_character_profile_organization_job(uuid, uuid, bigint, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_character_profile_organization_job(uuid, uuid, bigint, text, jsonb) TO service_role;

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
  v_hash := encode(extensions.digest(convert_to(public.character_profile_source_hash_payload(v_payload)::text, 'UTF8'), 'sha256'), 'hex');

  SELECT p.profile INTO v_profile
  FROM public.character_profile_organization p
  WHERE p.character_id = p_character_id
    AND p.author_id = p_author_id
    AND p.source_hash = v_hash;

  RETURN v_profile;
END;
$$;
REVOKE ALL ON FUNCTION public.get_character_ai_profile_for_chat(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_character_ai_profile_for_chat(uuid, uuid) TO service_role;
COMMIT;
