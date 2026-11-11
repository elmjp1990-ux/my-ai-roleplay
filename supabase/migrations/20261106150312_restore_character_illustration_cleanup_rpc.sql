-- Restore the isolated authorization gate required by the existing client-side
-- character illustration cleanup queue. This is intentionally independent from
-- the broader account-deletion / character-preservation migration.
CREATE OR REPLACE FUNCTION public.can_process_character_illustration_cleanup(
  p_job_id uuid,
  p_user_id uuid,
  p_storage_path text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_session_id uuid;
BEGIN
  -- Bind the RPC to the currently authenticated caller; never trust p_user_id alone.
  IF auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'not_allowed_to_process_character_asset_cleanup'
      USING ERRCODE = '42501';
  END IF;

  -- Pending account deletion freezes cleanup.
  IF NOT public.account_is_active() THEN
    RETURN false;
  END IF;

  -- Only process the exact job owned by this caller.
  IF NOT EXISTS (
    SELECT 1
    FROM public.character_illustration_cleanup_jobs AS j
    WHERE j.id = p_job_id
      AND j.author_id = p_user_id
      AND j.storage_path = p_storage_path
  ) THEN
    RETURN false;
  END IF;

  -- Reject missing, revoked, or mismatched auth sessions.
  v_session_id := NULLIF(auth.jwt() ->> 'session_id', '')::uuid;
  IF v_session_id IS NULL
     OR NOT EXISTS (
       SELECT 1
       FROM auth.sessions AS s
       WHERE s.id = v_session_id
         AND s.user_id = p_user_id
     )
     OR NOT EXISTS (
       SELECT 1
       FROM auth.users AS u
       WHERE u.id = p_user_id
     ) THEN
    RETURN false;
  END IF;

  -- Only accept the expected owner/character/illustration path shape.
  IF p_storage_path IS NULL
     OR p_storage_path !~ (
       '^' || p_user_id::text ||
       '/[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}' ||
       '/[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}[.](jpg|jpeg|png|webp)$'
     ) THEN
    RETURN false;
  END IF;

  -- Fail closed if any character illustration metadata or character video still
  -- references this exact object path.
  IF EXISTS (
    SELECT 1
    FROM public.character_illustrations AS ci
    WHERE ci.storage_path = p_storage_path
  ) OR EXISTS (
    SELECT 1
    FROM public.characters AS c
    WHERE c.avatar_video_path = p_storage_path
  ) THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$function$;

-- SECURITY DEFINER is necessary for the narrowly scoped auth/session and
-- reference checks; the function remains callable only by authenticated users.
REVOKE ALL ON FUNCTION public.can_process_character_illustration_cleanup(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.can_process_character_illustration_cleanup(uuid, uuid, text)
  TO authenticated;

COMMENT ON FUNCTION public.can_process_character_illustration_cleanup(uuid, uuid, text)
  IS 'Caller-bound, fail-closed authorization gate for queued character illustration Storage cleanup.';

NOTIFY pgrst, 'reload schema';
