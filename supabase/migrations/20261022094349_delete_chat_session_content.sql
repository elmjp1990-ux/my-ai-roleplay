CREATE OR REPLACE FUNCTION public.delete_chat_session_content(p_session_id uuid)
RETURNS TABLE(storage_path text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_paths text[] := ARRAY[]::text[];
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication_required' USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.account_deletion_requests r
    WHERE r.user_id = v_user_id
  ) THEN
    RAISE EXCEPTION 'account_deletion_pending' USING ERRCODE = '42501';
  END IF;

  PERFORM 1
  FROM public.chat_sessions s
  WHERE s.id = p_session_id
    AND s.user_id = v_user_id
    AND s.deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'session_not_found_or_not_owned' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(pg_catalog.array_agg(p.storage_path), ARRAY[]::text[])
    INTO v_paths
  FROM public.chat_memory_photos p
  WHERE p.session_id = p_session_id
    AND p.owner_id = v_user_id
    AND p.chat_type = 'single'
    AND p.deleted_at IS NULL
    AND p.storage_path IS NOT NULL;

  DELETE FROM public.chat_message_versions v
  WHERE v.message_id IN (
    SELECT m.id FROM public.chat_messages m WHERE m.session_id = p_session_id
  );

  UPDATE public.ai_generation_records
     SET original_content = ''
   WHERE session_id = p_session_id AND user_id = v_user_id;

  UPDATE public.chat_messages
     SET content = '', deleted_at = COALESCE(deleted_at, pg_catalog.now())
   WHERE session_id = p_session_id;

  UPDATE public.chat_memory_photos
     SET deleted_at = COALESCE(deleted_at, pg_catalog.now()),
         status = 'deleted'
   WHERE session_id = p_session_id
     AND owner_id = v_user_id
     AND chat_type = 'single'
     AND deleted_at IS NULL;

  UPDATE public.chat_sessions
     SET deleted_at = pg_catalog.now(),
         updated_at = pg_catalog.now(),
         session_data = (session_data - 'memories' - 'album' - 'openingMessage' - 'roleplayMeta' - 'pendingTurn')
           || pg_catalog.jsonb_build_object('memories', '[]'::jsonb, 'album', '[]'::jsonb),
         character_snapshot = '{}'::jsonb
   WHERE id = p_session_id AND user_id = v_user_id AND deleted_at IS NULL;

  RETURN QUERY SELECT pg_catalog.unnest(v_paths);
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_chat_session_content(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_chat_session_content(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_chat_session_content(uuid) TO authenticated;