-- Group chat billing: charge 3 currency units per character in the group turn.
-- Silver coins are consumed first; diamonds cover the remainder.
-- This currently wraps the deterministic mock turn atomically because the AI provider is not integrated yet.

CREATE TABLE IF NOT EXISTS public.chat_group_turn_charges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL REFERENCES public.chat_groups(id) ON DELETE CASCADE,
  group_turn_id uuid NOT NULL UNIQUE REFERENCES public.chat_group_turns(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  request_key uuid NOT NULL,
  member_count integer NOT NULL CHECK (member_count BETWEEN 1 AND 3),
  cost integer NOT NULL CHECK (cost = member_count * 3),
  silver_charged integer NOT NULL DEFAULT 0 CHECK (silver_charged >= 0),
  diamonds_charged integer NOT NULL DEFAULT 0 CHECK (diamonds_charged >= 0),
  status text NOT NULL DEFAULT 'settled' CHECK (status IN ('settled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chat_group_turn_charges_group_request_key UNIQUE (group_id, request_key)
);

ALTER TABLE public.chat_group_turn_charges ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.chat_group_turn_charges FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.chat_group_turn_charges TO service_role;

CREATE OR REPLACE FUNCTION public.append_chat_group_mock_turn(
  p_group_id uuid,
  p_request_key uuid,
  p_content text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_turn_id uuid;
  v_existing_content text;
  v_member_count integer;
  v_cost integer;
  v_silver integer;
  v_diamonds integer;
  v_balance_silver integer;
  v_balance_diamonds integer;
  v_pick integer;
  v_character_id uuid;
  v_scene_id uuid;
  v_character_name text;
  v_style text;
  v_scene_name text;
  v_character_snapshot jsonb;
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

  PERFORM 1
  FROM public.chat_groups g
  WHERE g.id = p_group_id
    AND g.owner_id = v_user_id
    AND g.archived_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'group_not_found_or_not_accessible' USING ERRCODE = '42501';
  END IF;

  -- A retry of an already committed request must not charge again.
  SELECT t.id, t.request_content
    INTO v_turn_id, v_existing_content
  FROM public.chat_group_turns t
  WHERE t.group_id = p_group_id
    AND t.request_key = p_request_key;
  IF FOUND THEN
    IF v_existing_content IS DISTINCT FROM btrim(p_content) THEN
      RAISE EXCEPTION 'idempotency_key_reused_with_different_content' USING ERRCODE = '22023';
    END IF;
    RETURN v_turn_id;
  END IF;

  SELECT count(*)::integer INTO v_member_count
  FROM public.chat_group_members m
  WHERE m.group_id = p_group_id;
  IF v_member_count NOT BETWEEN 1 AND 3 THEN
    RAISE EXCEPTION 'invalid_group_member_count' USING ERRCODE = '23514';
  END IF;

  -- Each character in the group costs 3. For 2 characters charge 6; for 3 charge 9.
  v_cost := v_member_count * 3;

  PERFORM public.ensure_wallet_account();

  SELECT w.silver_coins, w.diamonds
    INTO v_balance_silver, v_balance_diamonds
  FROM public.wallet_accounts w
  WHERE w.user_id = v_user_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'wallet_not_initialized' USING ERRCODE = 'P0001';
  END IF;

  IF COALESCE(v_balance_silver, 0) + COALESCE(v_balance_diamonds, 0) < v_cost THEN
    RAISE EXCEPTION 'group_insufficient_funds: required %, available %',
      v_cost, COALESCE(v_balance_silver, 0) + COALESCE(v_balance_diamonds, 0)
      USING ERRCODE = 'P0001';
  END IF;

  -- Silver coins are always consumed first; diamonds pay only the remainder.
  v_silver := LEAST(v_balance_silver, v_cost);
  v_diamonds := v_cost - v_silver;

  UPDATE public.wallet_accounts w
  SET silver_coins = w.silver_coins - v_silver,
      diamonds = w.diamonds - v_diamonds,
      updated_at = now()
  WHERE w.user_id = v_user_id;

  SELECT count(*)::integer % v_member_count INTO v_pick
  FROM public.chat_group_turns t
  WHERE t.group_id = p_group_id;

  INSERT INTO public.chat_group_turns(group_id, user_id, request_key, request_content)
  VALUES (p_group_id, v_user_id, p_request_key, btrim(p_content))
  ON CONFLICT (group_id, request_key) DO NOTHING
  RETURNING id INTO v_turn_id;

  -- Group row locking serializes requests; this is a defensive fallback for any
  -- future alternate writer and avoids charging if another writer won the key.
  IF v_turn_id IS NULL THEN
    RAISE EXCEPTION 'group_turn_request_conflict' USING ERRCODE = '40001';
  END IF;

  SELECT
    m.character_id,
    m.scene_id,
    m.character_snapshot,
    COALESCE(m.character_snapshot->>'name', '角色'),
    COALESCE(m.character_snapshot->>'style', m.character_snapshot->>'intro', '我會仔細留意目前的情況。'),
    COALESCE(s.name, '目前場景')
  INTO
    v_character_id,
    v_scene_id,
    v_character_snapshot,
    v_character_name,
    v_style,
    v_scene_name
  FROM public.chat_group_members m
  LEFT JOIN public.chat_group_scenes s
    ON s.id = m.scene_id AND s.group_id = m.group_id
  WHERE m.group_id = p_group_id
  ORDER BY m.position
  OFFSET v_pick
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'mock_director_no_valid_speaker' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.chat_group_messages(
    group_id, scene_id, turn_id, sequence_no, speaker_type, character_id, content
  )
  VALUES (p_group_id, v_scene_id, v_turn_id, 0, 'user', NULL, btrim(p_content));

  INSERT INTO public.chat_group_messages(
    group_id, scene_id, turn_id, sequence_no, speaker_type, character_id, content, speaker_snapshot
  )
  VALUES (
    p_group_id,
    v_scene_id,
    v_turn_id,
    1,
    'character',
    v_character_id,
    format('聽見你的話，%s 回應：「我明白了。%s 我們可以從「%s」開始，你接下來想怎麼做？」',
      v_character_name, v_style, v_scene_name),
    jsonb_build_object(
      'id', COALESCE(v_character_snapshot->>'id', v_character_id::text),
      'name', v_character_name
    )
  );

  INSERT INTO public.chat_group_turn_charges(
    group_id, group_turn_id, user_id, request_key,
    member_count, cost, silver_charged, diamonds_charged, status
  )
  VALUES (
    p_group_id, v_turn_id, v_user_id, p_request_key,
    v_member_count, v_cost, v_silver, v_diamonds, 'settled'
  );

  IF v_silver > 0 THEN
    INSERT INTO public.wallet_transactions(user_id, currency_type, amount, biz_type, reference_id)
    VALUES (v_user_id, 'silver_coins', -v_silver, 'group_chat_turn_charge', v_turn_id::text);
  END IF;
  IF v_diamonds > 0 THEN
    INSERT INTO public.wallet_transactions(user_id, currency_type, amount, biz_type, reference_id)
    VALUES (v_user_id, 'diamonds', -v_diamonds, 'group_chat_turn_charge', v_turn_id::text);
  END IF;

  UPDATE public.chat_groups SET updated_at = now() WHERE id = p_group_id;
  RETURN v_turn_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.append_chat_group_mock_turn(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.append_chat_group_mock_turn(uuid, uuid, text) TO authenticated, service_role;
