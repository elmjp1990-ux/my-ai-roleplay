-- Read watermarks must not update chat_sessions.updated_at: doing so makes a
-- harmless first-open read look like a concurrent content edit.
CREATE OR REPLACE FUNCTION public.mark_chat_session_read(
  p_session_id uuid,
  p_read_at bigint
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_read_at bigint;
BEGIN
  IF auth.uid() IS NULL OR p_session_id IS NULL OR p_read_at IS NULL OR p_read_at < 0 THEN
    RAISE EXCEPTION 'invalid_chat_read_watermark' USING ERRCODE = '22023';
  END IF;
  UPDATE public.chat_sessions s
  SET session_data = jsonb_set(
    COALESCE(s.session_data, '{}'::jsonb),
    '{lastReadAt}',
    to_jsonb(GREATEST(
      COALESCE(NULLIF(s.session_data->>'lastReadAt', '')::bigint, 0),
      p_read_at
    )),
    true
  )
  WHERE s.id = p_session_id
    AND s.user_id = (SELECT auth.uid())
    AND s.deleted_at IS NULL
  RETURNING (s.session_data->>'lastReadAt')::bigint INTO v_read_at;
  RETURN v_read_at;
END;
$function$;

REVOKE ALL ON FUNCTION public.mark_chat_session_read(uuid, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_chat_session_read(uuid, bigint) TO authenticated;


CREATE INDEX IF NOT EXISTS chat_sessions_active_story_character_page_idx
  ON public.chat_sessions (user_id, chat_mode, status, character_id, updated_at DESC, id DESC)
  WHERE deleted_at IS NULL;

CREATE OR REPLACE FUNCTION public.get_story_chat_sessions_page(
  p_pinned boolean,
  p_offset integer DEFAULT 0,
  p_limit integer DEFAULT 11
)
RETURNS TABLE (
  id uuid,user_id uuid,character_id uuid,character_name text,status text,chat_mode text,
  created_at timestamptz,updated_at timestamptz,character_snapshot_id text,character_snapshot_author_id text,
  session_name text,session_archived text,session_hidden text,session_pinned text,session_started_at text,
  session_encounter_mode text,session_has_user_message text,session_last_message_preview text,
  session_last_message_at text,session_last_assistant_message_at text,session_last_read_at text
)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path TO ''
AS $function$
BEGIN
  IF p_pinned IS NULL OR p_offset IS NULL OR p_offset < 0 OR p_offset > 100000
     OR p_limit IS NULL OR p_limit < 1 OR p_limit > 50 THEN
    RAISE EXCEPTION 'invalid_story_chat_page_request' USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
  WITH candidates AS (
    SELECT
      s.id,s.user_id,s.character_id,s.character_name,s.status,s.chat_mode,s.created_at,s.updated_at,
      s.character_snapshot->>'id' AS character_snapshot_id,
      s.character_snapshot->>'authorId' AS character_snapshot_author_id,
      s.session_data->>'name' AS session_name,
      s.session_data->>'archived' AS session_archived,
      s.session_data->>'hidden' AS session_hidden,
      s.session_data->>'pinned' AS session_pinned,
      s.session_data->>'startedAt' AS session_started_at,
      s.session_data->>'encounterMode' AS session_encounter_mode,
      s.session_data->>'hasUserMessage' AS session_has_user_message,
      s.session_data->>'lastMessagePreview' AS session_last_message_preview,
      s.session_data->>'lastMessageAt' AS session_last_message_at,
      s.session_data->>'lastAssistantMessageAt' AS session_last_assistant_message_at,
      s.session_data->>'lastReadAt' AS session_last_read_at,
      CASE
        WHEN COALESCE(s.session_data->>'lastMessageAt','') ~ '^[0-9]+([.][0-9]+)?$'
          THEN (s.session_data->>'lastMessageAt')::numeric
        ELSE EXTRACT(EPOCH FROM s.updated_at) * 1000
      END AS activity_sort,
      COALESCE(s.character_id::text,s.character_snapshot->>'id',s.id::text) AS character_key
    FROM public.chat_sessions s
    WHERE s.user_id = (SELECT auth.uid())
      AND s.deleted_at IS NULL
      AND s.status = 'active'
      AND s.chat_mode = 'story'
      AND COALESCE(s.session_data->>'archived','false') <> 'true'
      AND (
        COALESCE(s.session_data->>'hasUserMessage','true') <> 'false'
        OR EXISTS (
          SELECT 1 FROM public.chat_messages cm
          WHERE cm.session_id = s.id AND cm.role = 'user' AND cm.deleted_at IS NULL
        )
      )
  ),
  latest AS (
    SELECT DISTINCT ON (character_key) *
    FROM candidates
    ORDER BY character_key,activity_sort DESC,updated_at DESC,id DESC
  )
  SELECT
    l.id,l.user_id,l.character_id,l.character_name,l.status,l.chat_mode,l.created_at,l.updated_at,
    l.character_snapshot_id,l.character_snapshot_author_id,l.session_name,l.session_archived,l.session_hidden,
    l.session_pinned,l.session_started_at,l.session_encounter_mode,l.session_has_user_message,
    l.session_last_message_preview,l.session_last_message_at,l.session_last_assistant_message_at,l.session_last_read_at
  FROM latest l
  WHERE COALESCE(l.session_pinned,'false') = CASE WHEN p_pinned THEN 'true' ELSE 'false' END
  ORDER BY l.activity_sort DESC,l.updated_at DESC,l.id DESC
  OFFSET p_offset LIMIT p_limit;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_story_chat_sessions_page(boolean, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_story_chat_sessions_page(boolean, integer, integer) TO authenticated;
