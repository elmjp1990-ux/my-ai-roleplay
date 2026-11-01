-- PR #200: enforce parent-first locks for chat turn reservation and message writes.

CREATE OR REPLACE FUNCTION public.reserve_chat_turn(
  p_user_id uuid,
  p_turn_id uuid,
  p_session_id uuid,
  p_user_message_id uuid,
  p_assistant_message_id uuid
)
RETURNS TABLE(
  turn_id uuid,
  status text,
  silver_reserved integer,
  diamonds_reserved integer,
  balance_silver integer,
  balance_diamonds integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_charge public.chat_turn_charges%rowtype;
  v_wallet public.wallet_accounts%rowtype;
  v_silver integer;
  v_diamonds integer;
BEGIN
  IF p_user_id IS NULL OR p_turn_id IS NULL OR p_session_id IS NULL
     OR p_user_message_id IS NULL OR p_assistant_message_id IS NULL THEN
    RAISE EXCEPTION 'invalid_turn_request';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.account_deletion_requests r WHERE r.user_id = p_user_id
  ) THEN
    RAISE EXCEPTION 'account_not_active';
  END IF;

  -- Lock and validate the parent before any charge or wallet row.
  PERFORM 1
  FROM public.chat_sessions s
  WHERE s.id = p_session_id
    AND s.user_id = p_user_id
    AND s.deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'chat_session_not_owned_or_active';
  END IF;

  INSERT INTO public.chat_turn_charges(
    turn_id,user_id,session_id,user_message_id,expected_assistant_message_id,cost,status
  )
  VALUES (p_turn_id,p_user_id,p_session_id,p_user_message_id,p_assistant_message_id,2,'created')
  ON CONFLICT ON CONSTRAINT chat_turn_charges_pkey DO NOTHING;

  SELECT c.* INTO v_charge
  FROM public.chat_turn_charges c
  WHERE c.turn_id = p_turn_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'turn_not_found'; END IF;

  IF v_charge.user_id <> p_user_id
     OR v_charge.session_id <> p_session_id
     OR v_charge.user_message_id <> p_user_message_id
     OR v_charge.expected_assistant_message_id <> p_assistant_message_id THEN
    RAISE EXCEPTION 'turn_id_reuse_conflict';
  END IF;

  IF v_charge.status <> 'created' THEN
    SELECT w.silver_coins, w.diamonds
      INTO v_silver, v_diamonds
    FROM public.wallet_accounts w
    WHERE w.user_id = p_user_id;
    RETURN QUERY SELECT v_charge.turn_id, v_charge.status,
      v_charge.silver_reserved, v_charge.diamonds_reserved, v_silver, v_diamonds;
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.chat_messages m
    WHERE m.id = p_user_message_id
      AND m.session_id = p_session_id
      AND m.role = 'user'
      AND m.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'user_message_not_found';
  END IF;

  SELECT w.* INTO v_wallet
  FROM public.wallet_accounts w
  WHERE w.user_id = p_user_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'wallet_not_initialized'; END IF;

  IF v_wallet.silver_coins + v_wallet.diamonds < 2 THEN
    UPDATE public.chat_turn_charges c
    SET status='insufficient_funds', updated_at=now()
    WHERE c.turn_id=p_turn_id;
    INSERT INTO public.chat_turn_events(turn_id,user_id,event_type,stage,error_code)
    VALUES (p_turn_id,p_user_id,'insufficient_balance','reservation','insufficient_funds');
    RETURN QUERY SELECT p_turn_id, 'insufficient_funds'::text, 0, 0,
      v_wallet.silver_coins, v_wallet.diamonds;
    RETURN;
  END IF;

  v_silver := least(v_wallet.silver_coins, 2);
  v_diamonds := 2 - v_silver;

  UPDATE public.wallet_accounts w
  SET silver_coins=w.silver_coins-v_silver,
      diamonds=w.diamonds-v_diamonds,
      updated_at=now()
  WHERE w.user_id=p_user_id;

  IF v_silver > 0 THEN
    INSERT INTO public.wallet_transactions(user_id,currency_type,amount,biz_type,reference_id)
    VALUES (p_user_id,'silver_coins',-v_silver,'chat_turn_charge',p_turn_id::text);
  END IF;
  IF v_diamonds > 0 THEN
    INSERT INTO public.wallet_transactions(user_id,currency_type,amount,biz_type,reference_id)
    VALUES (p_user_id,'diamonds',-v_diamonds,'chat_turn_charge',p_turn_id::text);
  END IF;

  UPDATE public.chat_turn_charges c
  SET status='reserved', silver_reserved=v_silver, diamonds_reserved=v_diamonds,
      reserved_at=now(), updated_at=now()
  WHERE c.turn_id=p_turn_id;

  INSERT INTO public.chat_turn_events(turn_id,user_id,event_type,stage)
  VALUES (p_turn_id,p_user_id,'reserved','reservation');

  SELECT w.silver_coins, w.diamonds
    INTO v_silver, v_diamonds
  FROM public.wallet_accounts w
  WHERE w.user_id=p_user_id;

  RETURN QUERY SELECT p_turn_id, 'reserved'::text,
    (SELECT c.silver_reserved FROM public.chat_turn_charges c WHERE c.turn_id=p_turn_id),
    (SELECT c.diamonds_reserved FROM public.chat_turn_charges c WHERE c.turn_id=p_turn_id),
    v_silver, v_diamonds;
END;
$function$;

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
    AND g.deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'group_not_found_or_not_accessible' USING ERRCODE = '42501';
  END IF;

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

  v_cost := v_member_count * 3;
  PERFORM public.ensure_wallet_account();

  SELECT w.silver_coins, w.diamonds
    INTO v_balance_silver, v_balance_diamonds
  FROM public.wallet_accounts w
  WHERE w.user_id = v_user_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'wallet_not_initialized' USING ERRCODE = 'P0001'; END IF;

  IF COALESCE(v_balance_silver, 0) + COALESCE(v_balance_diamonds, 0) < v_cost THEN
    RAISE EXCEPTION 'group_insufficient_funds: required %, available %',
      v_cost, COALESCE(v_balance_silver, 0) + COALESCE(v_balance_diamonds, 0)
      USING ERRCODE = 'P0001';
  END IF;

  v_silver := LEAST(v_balance_silver, v_cost);
  v_diamonds := v_cost - v_silver;

  UPDATE public.wallet_accounts w
  SET silver_coins=w.silver_coins-v_silver,
      diamonds=w.diamonds-v_diamonds,
      updated_at=now()
  WHERE w.user_id=v_user_id;

  SELECT count(*)::integer % v_member_count INTO v_pick
  FROM public.chat_group_turns t
  WHERE t.group_id=p_group_id;

  INSERT INTO public.chat_group_turns(group_id,user_id,request_key,request_content)
  VALUES (p_group_id,v_user_id,p_request_key,btrim(p_content))
  ON CONFLICT (group_id,request_key) DO NOTHING
  RETURNING id INTO v_turn_id;

  IF v_turn_id IS NULL THEN
    RAISE EXCEPTION 'group_turn_request_conflict' USING ERRCODE = '40001';
  END IF;

  SELECT
    m.character_id,m.scene_id,m.character_snapshot,
    COALESCE(m.character_snapshot->>'name','角色'),
    COALESCE(m.character_snapshot->>'style',m.character_snapshot->>'intro','我會仔細留意目前的情況。'),
    COALESCE(s.name,'目前場景')
  INTO
    v_character_id,v_scene_id,v_character_snapshot,
    v_character_name,v_style,v_scene_name
  FROM public.chat_group_members m
  LEFT JOIN public.chat_group_scenes s
    ON s.id=m.scene_id AND s.group_id=m.group_id
  WHERE m.group_id=p_group_id
  ORDER BY m.position
  OFFSET v_pick
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'mock_director_no_valid_speaker' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.chat_group_messages(
    group_id,scene_id,turn_id,sequence_no,speaker_type,character_id,content
  )
  VALUES (p_group_id,v_scene_id,v_turn_id,0,'user',NULL,btrim(p_content));

  INSERT INTO public.chat_group_messages(
    group_id,scene_id,turn_id,sequence_no,speaker_type,character_id,content,speaker_snapshot
  )
  VALUES (
    p_group_id,v_scene_id,v_turn_id,1,'character',v_character_id,
    format('聽見你的話，%s 回應：「我明白了。%s 我們可以從「%s」開始，你接下來想怎麼做？」',
      v_character_name,v_style,v_scene_name),
    jsonb_build_object(
      'id',COALESCE(v_character_snapshot->>'id',v_character_id::text),
      'name',v_character_name
    )
  );

  INSERT INTO public.chat_group_turn_charges(
    group_id,group_turn_id,user_id,request_key,
    member_count,cost,silver_charged,diamonds_charged,status
  )
  VALUES (
    p_group_id,v_turn_id,v_user_id,p_request_key,
    v_member_count,v_cost,v_silver,v_diamonds,'settled'
  );

  IF v_silver > 0 THEN
    INSERT INTO public.wallet_transactions(user_id,currency_type,amount,biz_type,reference_id)
    VALUES (v_user_id,'silver_coins',-v_silver,'group_chat_turn_charge',v_turn_id::text);
  END IF;
  IF v_diamonds > 0 THEN
    INSERT INTO public.wallet_transactions(user_id,currency_type,amount,biz_type,reference_id)
    VALUES (v_user_id,'diamonds',-v_diamonds,'group_chat_turn_charge',v_turn_id::text);
  END IF;

  UPDATE public.chat_groups SET updated_at=now() WHERE id=p_group_id;
  RETURN v_turn_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.guard_chat_turn_assistant_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_charge public.chat_turn_charges%rowtype;
BEGIN
  -- Every message writer locks the session first, so deletion serializes with
  -- both user-message creation and assistant-message creation.
  PERFORM 1
  FROM public.chat_sessions s
  WHERE s.id = NEW.session_id
    AND s.deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'chat_session_not_found_or_deleted';
  END IF;

  SELECT c.* INTO v_charge
  FROM public.chat_turn_charges c
  WHERE c.expected_assistant_message_id = NEW.id
  FOR UPDATE;

  IF FOUND THEN
    IF NEW.role IS DISTINCT FROM 'assistant' THEN
      RAISE EXCEPTION 'expected_assistant_message_id_role_conflict';
    END IF;
    IF NEW.session_id IS DISTINCT FROM v_charge.session_id THEN
      RAISE EXCEPTION 'expected_assistant_message_session_conflict';
    END IF;
    IF v_charge.status IS DISTINCT FROM 'reserved'
       AND v_charge.status IS DISTINCT FROM 'needs_reconciliation' THEN
      RAISE EXCEPTION 'assistant_insert_requires_unresolved_charge';
    END IF;
    IF char_length(btrim(coalesce(NEW.content, ''))) = 0 THEN
      RAISE EXCEPTION 'assistant_reply_content_required';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.role = 'assistant' THEN
    RAISE EXCEPTION 'assistant_reply_requires_chat_turn';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.guard_chat_turn_assistant_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_locked_charge public.chat_turn_charges%rowtype;
  v_old_charge public.chat_turn_charges%rowtype;
  v_new_charge public.chat_turn_charges%rowtype;
  v_has_old_charge boolean := false;
  v_has_new_charge boolean := false;
  v_content_changed boolean;
  v_deleted_changed boolean;
BEGIN
  -- No edits or soft-deletes are allowed once the parent chat is deleted.
  PERFORM 1
  FROM public.chat_sessions s
  WHERE s.id = OLD.session_id
    AND s.deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'chat_session_not_found_or_deleted';
  END IF;

  IF NEW.role IS DISTINCT FROM OLD.role THEN
    RAISE EXCEPTION 'chat_message_role_is_immutable';
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.session_id IS DISTINCT FROM OLD.session_id THEN
    IF OLD.role = 'assistant' THEN
      RAISE EXCEPTION 'assistant_message_identity_is_immutable';
    ELSE
      RAISE EXCEPTION 'user_message_identity_is_immutable';
    END IF;
  END IF;

  IF OLD.role <> 'assistant' THEN
    RETURN NEW;
  END IF;

  v_content_changed := NEW.content IS DISTINCT FROM OLD.content;
  v_deleted_changed := NEW.deleted_at IS DISTINCT FROM OLD.deleted_at;

  FOR v_locked_charge IN
    SELECT c.*
    FROM public.chat_turn_charges c
    WHERE c.expected_assistant_message_id = OLD.id
       OR c.expected_assistant_message_id = NEW.id
    ORDER BY c.expected_assistant_message_id
    FOR UPDATE
  LOOP
    IF v_locked_charge.expected_assistant_message_id = OLD.id THEN
      v_old_charge := v_locked_charge;
      v_has_old_charge := true;
    END IF;
    IF v_locked_charge.expected_assistant_message_id = NEW.id THEN
      v_new_charge := v_locked_charge;
      v_has_new_charge := true;
    END IF;
  END LOOP;

  IF v_has_old_charge AND v_has_new_charge
     AND v_old_charge.turn_id IS DISTINCT FROM v_new_charge.turn_id THEN
    RAISE EXCEPTION 'assistant_message_turn_id_conflict';
  END IF;

  IF v_has_old_charge
     AND OLD.id IS DISTINCT FROM v_old_charge.expected_assistant_message_id THEN
    RAISE EXCEPTION 'assistant_message_turn_id_conflict';
  END IF;

  IF v_deleted_changed THEN
    IF v_content_changed THEN
      RAISE EXCEPTION 'assistant_reply_edit_and_delete_must_be_separate';
    END IF;
    IF v_has_old_charge AND v_old_charge.status IS DISTINCT FROM 'settled' THEN
      RAISE EXCEPTION 'chat_turn_reply_delete_requires_settled_charge';
    END IF;
    RETURN NEW;
  END IF;

  IF v_content_changed AND v_has_old_charge
     AND v_old_charge.status IS DISTINCT FROM 'settled' THEN
    RAISE EXCEPTION 'assistant_reply_edit_requires_settled_charge';
  END IF;

  RETURN NEW;
END;
$function$;
