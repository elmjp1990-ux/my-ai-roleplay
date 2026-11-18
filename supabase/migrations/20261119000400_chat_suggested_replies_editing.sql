-- Allow owners to edit or remove the latest generated reply suggestions without changing chat messages or billing.
-- chat_messages has an existing owner UPDATE policy for message editing.
-- Prevent that broad policy from becoming an alternate path for changing AI suggestions.
CREATE OR REPLACE FUNCTION public.guard_chat_message_suggested_replies_rpc_only()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $guard$
BEGIN
  IF current_user IN ('anon', 'authenticated') THEN
    RAISE EXCEPTION 'suggested_replies_rpc_required' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$guard$;

REVOKE ALL ON FUNCTION public.guard_chat_message_suggested_replies_rpc_only() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.guard_chat_message_suggested_replies_rpc_only() FROM anon, authenticated;

DROP TRIGGER IF EXISTS guard_chat_message_suggested_replies_rpc_only ON public.chat_messages;
CREATE TRIGGER guard_chat_message_suggested_replies_rpc_only
BEFORE UPDATE OF suggested_replies ON public.chat_messages
FOR EACH ROW
EXECUTE FUNCTION public.guard_chat_message_suggested_replies_rpc_only();

CREATE OR REPLACE FUNCTION public.update_chat_message_suggested_replies(
  p_message_id uuid,
  p_suggested_replies jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_session_id uuid;
  v_owner_id uuid;
  v_session_deleted_at timestamptz;
  v_message_role text;
  v_latest_message_id uuid;
  v_saved jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication_required' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.account_deletion_requests r WHERE r.user_id = v_user_id
  ) THEN
    RAISE EXCEPTION 'account_deletion_pending' USING ERRCODE = '42501';
  END IF;
  IF p_message_id IS NULL OR p_suggested_replies IS NULL
     OR pg_catalog.jsonb_typeof(p_suggested_replies) <> 'array'
     OR pg_catalog.jsonb_array_length(p_suggested_replies) > 3 THEN
    RAISE EXCEPTION 'invalid_suggested_replies' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_array_elements(p_suggested_replies) AS item(value)
    WHERE pg_catalog.jsonb_typeof(item.value) <> 'string'
       OR pg_catalog.char_length(pg_catalog.btrim(item.value #>> '{}')) NOT BETWEEN 1 AND 500
  ) THEN
    RAISE EXCEPTION 'invalid_suggested_reply_item' USING ERRCODE = '22023';
  END IF;

  SELECT s.id, s.user_id, s.deleted_at, m.role
    INTO v_session_id, v_owner_id, v_session_deleted_at, v_message_role
  FROM public.chat_messages m
  JOIN public.chat_sessions s ON s.id = m.session_id
  WHERE m.id = p_message_id
    AND m.deleted_at IS NULL
  FOR UPDATE OF s, m;

  IF NOT FOUND OR v_owner_id IS DISTINCT FROM v_user_id
     OR v_session_deleted_at IS NOT NULL OR v_message_role <> 'assistant' THEN
    RAISE EXCEPTION 'suggestion_message_not_found_or_not_owned' USING ERRCODE = '42501';
  END IF;

  SELECT m.id INTO v_latest_message_id
  FROM public.chat_messages m
  WHERE m.session_id = v_session_id
    AND m.role = 'assistant'
    AND m.deleted_at IS NULL
  ORDER BY m.created_at DESC, m.id DESC
  LIMIT 1;
  IF v_latest_message_id IS DISTINCT FROM p_message_id THEN
    RAISE EXCEPTION 'suggestion_message_not_latest' USING ERRCODE = '42501';
  END IF;

  UPDATE public.chat_messages m
  SET suggested_replies = p_suggested_replies
  WHERE m.id = p_message_id AND m.session_id = v_session_id
    AND m.role = 'assistant' AND m.deleted_at IS NULL
  RETURNING m.suggested_replies INTO v_saved;

  IF v_saved IS NULL THEN
    RAISE EXCEPTION 'suggested_replies_update_failed' USING ERRCODE = '40001';
  END IF;
  RETURN v_saved;
END;
$function$;

REVOKE ALL ON FUNCTION public.update_chat_message_suggested_replies(uuid,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_chat_message_suggested_replies(uuid,jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_chat_message_suggested_replies(uuid,jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.update_chat_group_turn_suggested_replies(
  p_turn_id uuid,
  p_suggested_replies jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_group_id uuid;
  v_owner_id uuid;
  v_group_deleted_at timestamptz;
  v_turn_user_id uuid;
  v_turn_status text;
  v_latest_turn_id uuid;
  v_saved jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication_required' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.account_deletion_requests r WHERE r.user_id = v_user_id
  ) THEN
    RAISE EXCEPTION 'account_deletion_pending' USING ERRCODE = '42501';
  END IF;
  IF p_turn_id IS NULL OR p_suggested_replies IS NULL
     OR pg_catalog.jsonb_typeof(p_suggested_replies) <> 'array'
     OR pg_catalog.jsonb_array_length(p_suggested_replies) > 3 THEN
    RAISE EXCEPTION 'invalid_suggested_replies' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_array_elements(p_suggested_replies) AS item(value)
    WHERE pg_catalog.jsonb_typeof(item.value) <> 'string'
       OR pg_catalog.char_length(pg_catalog.btrim(item.value #>> '{}')) NOT BETWEEN 1 AND 500
  ) THEN
    RAISE EXCEPTION 'invalid_suggested_reply_item' USING ERRCODE = '22023';
  END IF;

  SELECT g.id, g.owner_id, g.deleted_at, t.user_id, t.status
    INTO v_group_id, v_owner_id, v_group_deleted_at, v_turn_user_id, v_turn_status
  FROM public.chat_group_turns t
  JOIN public.chat_groups g ON g.id = t.group_id
  WHERE t.id = p_turn_id
  FOR UPDATE OF g, t;

  IF NOT FOUND OR v_owner_id IS DISTINCT FROM v_user_id
     OR v_turn_user_id IS DISTINCT FROM v_user_id
     OR v_group_deleted_at IS NOT NULL OR v_turn_status <> 'completed' THEN
    RAISE EXCEPTION 'suggestion_turn_not_found_or_not_owned' USING ERRCODE = '42501';
  END IF;

  SELECT t.id INTO v_latest_turn_id
  FROM public.chat_group_turns t
  WHERE t.group_id = v_group_id AND t.status = 'completed'
  ORDER BY t.created_at DESC, t.id DESC
  LIMIT 1;
  IF v_latest_turn_id IS DISTINCT FROM p_turn_id THEN
    RAISE EXCEPTION 'suggestion_turn_not_latest' USING ERRCODE = '42501';
  END IF;

  UPDATE public.chat_group_turns t
  SET suggested_replies = p_suggested_replies
  WHERE t.id = p_turn_id AND t.group_id = v_group_id
    AND t.user_id = v_user_id AND t.status = 'completed'
  RETURNING t.suggested_replies INTO v_saved;

  IF v_saved IS NULL THEN
    RAISE EXCEPTION 'suggested_replies_update_failed' USING ERRCODE = '40001';
  END IF;
  RETURN v_saved;
END;
$function$;

REVOKE ALL ON FUNCTION public.update_chat_group_turn_suggested_replies(uuid,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_chat_group_turn_suggested_replies(uuid,jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_chat_group_turn_suggested_replies(uuid,jsonb) TO authenticated;
