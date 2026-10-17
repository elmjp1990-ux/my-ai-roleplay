-- Prevent pending-deletion accounts from creating additional mock group turns.
-- Keep the existing authenticated RPC, ownership check, and idempotency behavior.
CREATE OR REPLACE FUNCTION public.append_chat_group_mock_turn(
  p_group_id uuid,
  p_request_key uuid,
  p_content text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_turn_id uuid;
  v_existing_content text;
  v_member_count integer;
  v_pick integer;
  v_character_id uuid;
  v_scene_id uuid;
  v_character_name text;
  v_style text;
  v_scene_name text;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication_required' USING ERRCODE = '42501';
  END IF;
  IF NOT public.account_is_active() THEN
    RAISE EXCEPTION 'account_deletion_pending' USING ERRCODE = '42501';
  END IF;
  IF p_request_key IS NULL THEN
    RAISE EXCEPTION 'request_key_required' USING ERRCODE = '22023';
  END IF;
  IF p_content IS NULL OR char_length(btrim(p_content)) NOT BETWEEN 1 AND 2000 THEN
    RAISE EXCEPTION 'invalid_message_content' USING ERRCODE = '22023';
  END IF;

  -- Serialize turns for one group so speaker rotation and sequence remain stable.
  PERFORM 1 FROM public.chat_groups g
  WHERE g.id = p_group_id
    AND g.owner_id = v_user_id
    AND g.archived_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'group_not_found_or_not_accessible' USING ERRCODE = '42501';
  END IF;

  SELECT t.id, t.request_content
    INTO v_turn_id, v_existing_content
  FROM public.chat_group_turns t
  WHERE t.group_id = p_group_id AND t.request_key = p_request_key;

  IF FOUND THEN
    IF v_existing_content IS DISTINCT FROM btrim(p_content) THEN
      RAISE EXCEPTION 'idempotency_key_reused_with_different_content' USING ERRCODE = '22023';
    END IF;
    RETURN v_turn_id;
  END IF;

  SELECT count(*) INTO v_member_count
  FROM public.chat_group_members m
  WHERE m.group_id = p_group_id;
  IF v_member_count NOT BETWEEN 1 AND 3 THEN
    RAISE EXCEPTION 'invalid_group_member_count' USING ERRCODE = '23514';
  END IF;

  SELECT count(*)::integer % v_member_count INTO v_pick
  FROM public.chat_group_turns t
  WHERE t.group_id = p_group_id;

  INSERT INTO public.chat_group_turns(group_id, user_id, request_key, request_content)
  VALUES (p_group_id, v_user_id, p_request_key, btrim(p_content))
  ON CONFLICT (group_id, request_key) DO NOTHING
  RETURNING id INTO v_turn_id;

  IF v_turn_id IS NULL THEN
    SELECT t.id, t.request_content INTO v_turn_id, v_existing_content
    FROM public.chat_group_turns t
    WHERE t.group_id = p_group_id AND t.request_key = p_request_key;
    IF v_existing_content IS DISTINCT FROM btrim(p_content) THEN
      RAISE EXCEPTION 'idempotency_key_reused_with_different_content' USING ERRCODE = '22023';
    END IF;
    RETURN v_turn_id;
  END IF;

  SELECT m.character_id, m.scene_id,
         COALESCE(m.character_snapshot->>'name', '角色'),
         COALESCE(m.character_snapshot->>'style', m.character_snapshot->>'intro', '我會仔細留意目前的情況。'),
         COALESCE(s.name, '目前場景')
    INTO v_character_id, v_scene_id, v_character_name, v_style, v_scene_name
  FROM public.chat_group_members m
  LEFT JOIN public.chat_group_scenes s
    ON s.id = m.scene_id AND s.group_id = m.group_id
  WHERE m.group_id = p_group_id
  ORDER BY m.position
  OFFSET v_pick
  LIMIT 1;

  IF v_character_id IS NULL THEN
    RAISE EXCEPTION 'mock_director_no_valid_speaker' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.chat_group_messages(
    group_id, scene_id, turn_id, sequence_no, speaker_type, character_id, content
  ) VALUES (
    p_group_id, v_scene_id, v_turn_id, 0, 'user', NULL, btrim(p_content)
  );

  INSERT INTO public.chat_group_messages(
    group_id, scene_id, turn_id, sequence_no, speaker_type, character_id, content
  ) VALUES (
    p_group_id, v_scene_id, v_turn_id, 1, 'character', v_character_id,
    format('聽見你的話，%s 回應：「我明白了。%s 我們可以從「%s」開始，你接下來想怎麼做？」',
      v_character_name, v_style, v_scene_name)
  );

  UPDATE public.chat_groups SET updated_at = now() WHERE id = p_group_id;

  RETURN v_turn_id;
END;
$function$;