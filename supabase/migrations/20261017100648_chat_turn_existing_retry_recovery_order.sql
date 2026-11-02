CREATE OR REPLACE FUNCTION public.reserve_chat_turn(
  p_user_id uuid,
  p_turn_id uuid,
  p_session_id uuid,
  p_user_message_id uuid,
  p_assistant_message_id uuid
)
RETURNS TABLE(turn_id uuid, status text, silver_reserved integer, diamonds_reserved integer, balance_silver integer, balance_diamonds integer)
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
  IF p_user_id IS NULL OR p_turn_id IS NULL OR p_session_id IS NULL OR p_user_message_id IS NULL OR p_assistant_message_id IS NULL THEN
    RAISE EXCEPTION 'invalid_turn_request';
  END IF;
  IF EXISTS (SELECT 1 FROM public.account_deletion_requests r WHERE r.user_id = p_user_id) THEN
    RAISE EXCEPTION 'account_not_active';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.chat_sessions s WHERE s.id = p_session_id AND s.user_id = p_user_id AND s.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'chat_session_not_owned_or_active';
  END IF;

  -- Find and lock the stable turn before checking message visibility so existing turns can recover idempotently.
  INSERT INTO public.chat_turn_charges(turn_id,user_id,session_id,user_message_id,expected_assistant_message_id,cost,status)
  VALUES (p_turn_id,p_user_id,p_session_id,p_user_message_id,p_assistant_message_id,2,'created')
  ON CONFLICT ON CONSTRAINT chat_turn_charges_pkey DO NOTHING;

  SELECT c.* INTO v_charge FROM public.chat_turn_charges c WHERE c.turn_id = p_turn_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'turn_not_found'; END IF;
  IF v_charge.user_id <> p_user_id OR v_charge.session_id <> p_session_id OR v_charge.user_message_id <> p_user_message_id OR v_charge.expected_assistant_message_id <> p_assistant_message_id THEN
    RAISE EXCEPTION 'turn_id_reuse_conflict';
  END IF;

  IF v_charge.status <> 'created' THEN
    SELECT w.silver_coins, w.diamonds INTO v_silver, v_diamonds FROM public.wallet_accounts w WHERE w.user_id = p_user_id;
    RETURN QUERY SELECT v_charge.turn_id, v_charge.status, v_charge.silver_reserved, v_charge.diamonds_reserved, v_silver, v_diamonds;
    RETURN;
  END IF;

  -- New reservations still require a non-deleted user message.
  IF NOT EXISTS (SELECT 1 FROM public.chat_messages m WHERE m.id = p_user_message_id AND m.session_id = p_session_id AND m.role = 'user' AND m.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'user_message_not_found';
  END IF;

  SELECT w.* INTO v_wallet FROM public.wallet_accounts w WHERE w.user_id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'wallet_not_initialized'; END IF;
  IF v_wallet.silver_coins + v_wallet.diamonds < 2 THEN
    UPDATE public.chat_turn_charges c SET status='insufficient_funds', updated_at=now() WHERE c.turn_id=p_turn_id;
    INSERT INTO public.chat_turn_events(turn_id,user_id,event_type,stage,error_code) VALUES (p_turn_id,p_user_id,'insufficient_balance','reservation','insufficient_funds');
    RETURN QUERY SELECT p_turn_id, 'insufficient_funds'::text, 0, 0, v_wallet.silver_coins, v_wallet.diamonds;
    RETURN;
  END IF;
  v_silver := least(v_wallet.silver_coins, 2);
  v_diamonds := 2 - v_silver;
  UPDATE public.wallet_accounts w SET silver_coins=w.silver_coins-v_silver, diamonds=w.diamonds-v_diamonds, updated_at=now() WHERE w.user_id=p_user_id;
  IF v_silver > 0 THEN INSERT INTO public.wallet_transactions(user_id,currency_type,amount,biz_type,reference_id) VALUES (p_user_id,'silver_coins',-v_silver,'chat_turn_charge',p_turn_id::text); END IF;
  IF v_diamonds > 0 THEN INSERT INTO public.wallet_transactions(user_id,currency_type,amount,biz_type,reference_id) VALUES (p_user_id,'diamonds',-v_diamonds,'chat_turn_charge',p_turn_id::text); END IF;
  UPDATE public.chat_turn_charges c SET status='reserved', silver_reserved=v_silver, diamonds_reserved=v_diamonds, reserved_at=now(), updated_at=now() WHERE c.turn_id=p_turn_id;
  INSERT INTO public.chat_turn_events(turn_id,user_id,event_type,stage) VALUES (p_turn_id,p_user_id,'reserved','reservation');
  SELECT w.silver_coins, w.diamonds INTO v_silver, v_diamonds FROM public.wallet_accounts w WHERE w.user_id=p_user_id;
  RETURN QUERY SELECT p_turn_id, 'reserved'::text,
    (SELECT c.silver_reserved FROM public.chat_turn_charges c WHERE c.turn_id=p_turn_id),
    (SELECT c.diamonds_reserved FROM public.chat_turn_charges c WHERE c.turn_id=p_turn_id), v_silver, v_diamonds;
END;
$function$;