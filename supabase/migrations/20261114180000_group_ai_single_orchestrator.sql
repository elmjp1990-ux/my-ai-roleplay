-- Single-call group AI orchestration with atomic per-character billing.
-- The Edge Function is the only caller of the service-role RPCs below.
ALTER TABLE public.chat_group_turns
  DROP CONSTRAINT IF EXISTS chat_group_turns_status_check;
ALTER TABLE public.chat_group_turns
  ADD CONSTRAINT chat_group_turns_status_check
  CHECK (status IN ('processing', 'completed', 'failed'));
ALTER TABLE public.chat_group_turns
  ALTER COLUMN completed_at DROP NOT NULL;
ALTER TABLE public.chat_group_turns
  ADD COLUMN IF NOT EXISTS processing_started_at timestamptz,
  ADD COLUMN IF NOT EXISTS failure_code text;

UPDATE public.chat_group_turns
SET status = 'completed',
    completed_at = COALESCE(completed_at, created_at)
WHERE status NOT IN ('processing', 'completed', 'failed');

ALTER TABLE public.chat_group_turn_charges
  DROP CONSTRAINT IF EXISTS chat_group_turn_charges_status_check;
ALTER TABLE public.chat_group_turn_charges
  ADD CONSTRAINT chat_group_turn_charges_status_check
  CHECK (status IN ('reserved', 'settled', 'refunded'));

-- Retire the old direct-to-database mock path. All new turns must go through
-- the authenticated group-chat-turn Edge Function.
REVOKE ALL ON FUNCTION public.append_chat_group_mock_turn(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.reserve_group_chat_turn(
  p_user_id uuid,
  p_group_id uuid,
  p_request_key uuid,
  p_content text
)
RETURNS TABLE (
  turn_id uuid,
  turn_status text,
  charge_status text,
  is_new boolean,
  member_count integer,
  cost integer,
  silver_charged integer,
  diamonds_charged integer,
  balance_silver integer,
  balance_diamonds integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_turn public.chat_group_turns%rowtype;
  v_charge public.chat_group_turn_charges%rowtype;
  v_wallet public.wallet_accounts%rowtype;
  v_member_count integer;
  v_cost integer;
  v_silver integer;
  v_diamonds integer;
BEGIN
  IF p_user_id IS NULL OR p_group_id IS NULL OR p_request_key IS NULL THEN
    RAISE EXCEPTION 'group_turn_identifiers_required' USING ERRCODE = '22023';
  END IF;
  IF p_content IS NULL OR char_length(btrim(p_content)) NOT BETWEEN 1 AND 2000 THEN
    RAISE EXCEPTION 'invalid_message_content' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.account_deletion_requests r WHERE r.user_id = p_user_id
  ) THEN
    RAISE EXCEPTION 'account_deletion_pending' USING ERRCODE = '42501';
  END IF;

  PERFORM 1 FROM public.chat_groups g
  WHERE g.id = p_group_id
    AND g.owner_id = p_user_id
    AND g.archived_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'group_not_found_or_not_accessible' USING ERRCODE = '42501';
  END IF;

  SELECT t.* INTO v_turn
  FROM public.chat_group_turns t
  WHERE t.group_id = p_group_id AND t.request_key = p_request_key
  FOR UPDATE;
  IF FOUND THEN
    IF v_turn.user_id <> p_user_id OR v_turn.request_content IS DISTINCT FROM btrim(p_content) THEN
      RAISE EXCEPTION 'idempotency_key_reused_with_different_content' USING ERRCODE = '22023';
    END IF;
    SELECT c.* INTO v_charge
    FROM public.chat_group_turn_charges c
    WHERE c.group_turn_id = v_turn.id;
    SELECT w.* INTO v_wallet FROM public.wallet_accounts w WHERE w.user_id = p_user_id;
    RETURN QUERY SELECT
      v_turn.id, v_turn.status, COALESCE(v_charge.status, 'missing'), false,
      COALESCE(v_charge.member_count, 0), COALESCE(v_charge.cost, 0),
      COALESCE(v_charge.silver_charged, 0), COALESCE(v_charge.diamonds_charged, 0),
      COALESCE(v_wallet.silver_coins, 0), COALESCE(v_wallet.diamonds, 0);
    RETURN;
  END IF;

  SELECT count(*)::integer INTO v_member_count
  FROM public.chat_group_members m
  WHERE m.group_id = p_group_id AND m.character_snapshot IS NOT NULL;
  IF v_member_count NOT BETWEEN 1 AND 3 THEN
    RAISE EXCEPTION 'invalid_group_member_count' USING ERRCODE = '23514';
  END IF;

  v_cost := v_member_count * 3;
  SELECT w.* INTO v_wallet
  FROM public.wallet_accounts w
  WHERE w.user_id = p_user_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'wallet_not_initialized'; END IF;

  IF COALESCE(v_wallet.silver_coins, 0) + COALESCE(v_wallet.diamonds, 0) < v_cost THEN
    RAISE EXCEPTION 'group_insufficient_funds: required %, available %',
      v_cost, COALESCE(v_wallet.silver_coins, 0) + COALESCE(v_wallet.diamonds, 0)
      USING ERRCODE = 'P0001';
  END IF;

  v_silver := LEAST(COALESCE(v_wallet.silver_coins, 0), v_cost);
  v_diamonds := v_cost - v_silver;
  UPDATE public.wallet_accounts w
  SET silver_coins = w.silver_coins - v_silver,
      diamonds = w.diamonds - v_diamonds,
      updated_at = now()
  WHERE w.user_id = p_user_id
  RETURNING w.* INTO v_wallet;

  INSERT INTO public.chat_group_turns(
    group_id, user_id, request_key, request_content, status, completed_at, processing_started_at
  ) VALUES (
    p_group_id, p_user_id, p_request_key, btrim(p_content), 'processing', NULL, now()
  )
  RETURNING * INTO v_turn;

  INSERT INTO public.chat_group_turn_charges(
    group_id, group_turn_id, user_id, request_key, member_count, cost,
    silver_charged, diamonds_charged, status
  ) VALUES (
    p_group_id, v_turn.id, p_user_id, p_request_key, v_member_count, v_cost,
    v_silver, v_diamonds, 'reserved'
  ) RETURNING * INTO v_charge;

  INSERT INTO public.chat_group_messages(
    group_id, scene_id, turn_id, sequence_no, speaker_type, character_id, content
  ) VALUES (
    p_group_id, NULL, v_turn.id, 0, 'user', NULL, btrim(p_content)
  );

  IF v_silver > 0 THEN
    INSERT INTO public.wallet_transactions(user_id, currency_type, amount, biz_type, reference_id)
    VALUES (p_user_id, 'silver_coins', -v_silver, 'group_chat_turn_charge', v_turn.id::text);
  END IF;
  IF v_diamonds > 0 THEN
    INSERT INTO public.wallet_transactions(user_id, currency_type, amount, biz_type, reference_id)
    VALUES (p_user_id, 'diamonds', -v_diamonds, 'group_chat_turn_charge', v_turn.id::text);
  END IF;

  UPDATE public.chat_groups SET updated_at = now() WHERE id = p_group_id;
  RETURN QUERY SELECT v_turn.id, v_turn.status, v_charge.status, true,
    v_member_count, v_cost, v_silver, v_diamonds,
    v_wallet.silver_coins, v_wallet.diamonds;
END;
$function$;

CREATE OR REPLACE FUNCTION public.complete_group_chat_turn(
  p_user_id uuid,
  p_turn_id uuid,
  p_speeches jsonb
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_turn public.chat_group_turns%rowtype;
  v_charge public.chat_group_turn_charges%rowtype;
  v_speech jsonb;
  v_character_id uuid;
  v_content text;
  v_scene_id uuid;
  v_snapshot jsonb;
  v_sequence integer := 0;
  v_count integer := 0;
BEGIN
  SELECT t.* INTO v_turn
  FROM public.chat_group_turns t
  WHERE t.id = p_turn_id AND t.user_id = p_user_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'group_turn_not_found'; END IF;

  SELECT c.* INTO v_charge
  FROM public.chat_group_turn_charges c
  WHERE c.group_turn_id = p_turn_id
  FOR UPDATE;
  IF NOT FOUND OR v_charge.user_id <> p_user_id THEN
    RAISE EXCEPTION 'group_turn_charge_not_found';
  END IF;
  IF v_turn.status = 'completed' AND v_charge.status = 'settled' THEN RETURN 'completed'; END IF;
  IF v_turn.status <> 'processing' OR v_charge.status <> 'reserved' THEN
    RAISE EXCEPTION 'group_turn_not_completable';
  END IF;
  IF jsonb_typeof(p_speeches) IS DISTINCT FROM 'array'
    OR jsonb_array_length(p_speeches) NOT BETWEEN 1 AND 3 THEN
    RAISE EXCEPTION 'invalid_group_speeches' USING ERRCODE = '22023';
  END IF;

  FOR v_speech IN SELECT value FROM jsonb_array_elements(p_speeches)
  LOOP
    IF jsonb_typeof(v_speech) IS DISTINCT FROM 'object'
      OR jsonb_typeof(v_speech->'speaker_id') IS DISTINCT FROM 'string'
      OR jsonb_typeof(v_speech->'content') IS DISTINCT FROM 'string' THEN
      RAISE EXCEPTION 'invalid_group_speech' USING ERRCODE = '22023';
    END IF;
    BEGIN
      v_character_id := (v_speech->>'speaker_id')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'invalid_group_speaker_id' USING ERRCODE = '22023';
    END;
    v_content := btrim(v_speech->>'content');
    IF char_length(v_content) NOT BETWEEN 1 AND 20000 THEN
      RAISE EXCEPTION 'invalid_group_speech_content' USING ERRCODE = '22023';
    END IF;

    SELECT m.scene_id, m.character_snapshot INTO v_scene_id, v_snapshot
    FROM public.chat_group_members m
    WHERE m.group_id = v_turn.group_id
      AND COALESCE(m.character_id, NULLIF(m.character_snapshot->>'id', '')::uuid) = v_character_id
    FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'group_speaker_not_member' USING ERRCODE = '22023'; END IF;

    v_sequence := v_sequence + 1;
    INSERT INTO public.chat_group_messages(
      group_id, scene_id, turn_id, sequence_no, speaker_type, character_id,
      content, speaker_snapshot
    ) VALUES (
      v_turn.group_id, v_scene_id, p_turn_id, v_sequence, 'character',
      v_character_id, v_content,
      jsonb_build_object('id', COALESCE(v_snapshot->>'id', v_character_id::text),
                         'name', COALESCE(v_snapshot->>'name', '角色'))
    );
    v_count := v_count + 1;
  END LOOP;

  UPDATE public.chat_group_turn_charges
  SET status = 'settled'
  WHERE group_turn_id = p_turn_id AND status = 'reserved';
  IF NOT FOUND THEN RAISE EXCEPTION 'group_charge_settlement_conflict'; END IF;

  UPDATE public.chat_group_turns
  SET status = 'completed', completed_at = now(), failure_code = NULL
  WHERE id = p_turn_id AND status = 'processing';
  IF NOT FOUND THEN RAISE EXCEPTION 'group_turn_completion_conflict'; END IF;

  UPDATE public.chat_groups SET updated_at = now() WHERE id = v_turn.group_id;
  RETURN 'completed';
END;
$function$;

CREATE OR REPLACE FUNCTION public.refund_group_chat_turn(
  p_user_id uuid,
  p_turn_id uuid,
  p_failure_code text
)
RETURNS TABLE(status text, balance_silver integer, balance_diamonds integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_turn public.chat_group_turns%rowtype;
  v_charge public.chat_group_turn_charges%rowtype;
  v_wallet public.wallet_accounts%rowtype;
BEGIN
  SELECT t.* INTO v_turn
  FROM public.chat_group_turns t
  WHERE t.id = p_turn_id AND t.user_id = p_user_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'group_turn_not_found'; END IF;

  SELECT c.* INTO v_charge
  FROM public.chat_group_turn_charges c
  WHERE c.group_turn_id = p_turn_id
  FOR UPDATE;
  IF NOT FOUND OR v_charge.user_id <> p_user_id THEN RAISE EXCEPTION 'group_turn_charge_not_found'; END IF;

  IF v_charge.status = 'refunded' THEN
    SELECT w.* INTO v_wallet FROM public.wallet_accounts w WHERE w.user_id = p_user_id;
    RETURN QUERY SELECT 'refunded'::text, v_wallet.silver_coins, v_wallet.diamonds;
    RETURN;
  END IF;
  IF v_charge.status = 'settled' OR v_turn.status = 'completed' THEN
    RAISE EXCEPTION 'completed_group_turn_cannot_be_refunded';
  END IF;
  IF v_charge.status <> 'reserved' OR v_turn.status <> 'processing' THEN
    RAISE EXCEPTION 'group_turn_not_refundable';
  END IF;

  SELECT w.* INTO v_wallet
  FROM public.wallet_accounts w WHERE w.user_id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'wallet_not_initialized'; END IF;

  UPDATE public.wallet_accounts w
  SET silver_coins = w.silver_coins + v_charge.silver_charged,
      diamonds = w.diamonds + v_charge.diamonds_charged,
      updated_at = now()
  WHERE w.user_id = p_user_id
  RETURNING w.* INTO v_wallet;

  IF v_charge.silver_charged > 0 THEN
    INSERT INTO public.wallet_transactions(user_id, currency_type, amount, biz_type, reference_id)
    VALUES (p_user_id, 'silver_coins', v_charge.silver_charged, 'group_chat_turn_refund', p_turn_id::text);
  END IF;
  IF v_charge.diamonds_charged > 0 THEN
    INSERT INTO public.wallet_transactions(user_id, currency_type, amount, biz_type, reference_id)
    VALUES (p_user_id, 'diamonds', v_charge.diamonds_charged, 'group_chat_turn_refund', p_turn_id::text);
  END IF;

  DELETE FROM public.chat_group_messages WHERE turn_id = p_turn_id;
  UPDATE public.chat_group_turn_charges SET status = 'refunded' WHERE group_turn_id = p_turn_id;
  UPDATE public.chat_group_turns
  SET status = 'failed', failure_code = left(coalesce(p_failure_code, 'confirmed_failure'), 80)
  WHERE id = p_turn_id;

  RETURN QUERY SELECT 'refunded'::text, v_wallet.silver_coins, v_wallet.diamonds;
END;
$function$;

REVOKE ALL ON FUNCTION public.reserve_group_chat_turn(uuid, uuid, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.complete_group_chat_turn(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.refund_group_chat_turn(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_group_chat_turn(uuid, uuid, uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.complete_group_chat_turn(uuid, uuid, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.refund_group_chat_turn(uuid, uuid, text) TO service_role;


-- Store provider diagnostics and token/cost metadata without storing prompts,
-- player messages, raw model output, or credentials.
CREATE TABLE IF NOT EXISTS public.chat_group_ai_usage (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL REFERENCES public.chat_groups(id) ON DELETE CASCADE,
  group_turn_id uuid NOT NULL UNIQUE REFERENCES public.chat_group_turns(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  requested_model text NOT NULL,
  returned_model text,
  upstream_provider text,
  gateway_request_id text,
  prompt_tokens integer,
  completion_tokens integer,
  total_tokens integer,
  cost_usd numeric(14,8),
  status text NOT NULL CHECK (status IN ('completed', 'failed')),
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.chat_group_ai_usage ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.chat_group_ai_usage FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.chat_group_ai_usage TO service_role;
