-- Do not recover pre-expiry reservations from a terminal/cancelled lifecycle.
-- Active, paused, and ready_to_settle are the only states that may finish a paid turn.
CREATE OR REPLACE FUNCTION public.reserve_encounter_chat_turn(
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
SET search_path = ''
AS $$
DECLARE
  l public.encounter_session_lifecycle%ROWTYPE;
  c public.chat_turn_charges%ROWTYPE;
  v_existing boolean := false;
BEGIN
  IF p_user_id IS NULL OR p_turn_id IS NULL OR p_session_id IS NULL
     OR p_user_message_id IS NULL OR p_assistant_message_id IS NULL THEN
    RAISE EXCEPTION 'invalid_turn_request' USING ERRCODE='22023';
  END IF;

  SELECT * INTO l
  FROM public.encounter_session_lifecycle
  WHERE session_id=p_session_id
  FOR UPDATE;

  IF NOT FOUND OR l.user_id IS DISTINCT FROM p_user_id
     OR l.status NOT IN ('active','paused','ready_to_settle') THEN
    RAISE EXCEPTION 'encounter_scene_expired_or_inactive' USING ERRCODE='23514';
  END IF;

  SELECT charge.* INTO c
  FROM public.chat_turn_charges AS charge
  WHERE charge.turn_id=p_turn_id
  FOR UPDATE;
  v_existing := FOUND;

  IF v_existing THEN
    IF c.user_id IS DISTINCT FROM p_user_id
       OR c.session_id IS DISTINCT FROM p_session_id
       OR c.user_message_id IS DISTINCT FROM p_user_message_id
       OR c.expected_assistant_message_id IS DISTINCT FROM p_assistant_message_id THEN
      RAISE EXCEPTION 'turn_id_reuse_conflict' USING ERRCODE='23505';
    END IF;

    IF c.status='insufficient_funds' THEN
      RETURN QUERY
      SELECT r.turn_id,r.status,r.silver_reserved,r.diamonds_reserved,r.balance_silver,r.balance_diamonds
      FROM public.reserve_chat_turn(
        p_user_id,p_turn_id,p_session_id,p_user_message_id,p_assistant_message_id
      ) AS r;
      RETURN;
    END IF;

    IF c.status IN ('reserved','needs_reconciliation','settled','refunded')
       AND c.reserved_at IS NOT NULL
       AND c.reserved_at <= l.scheduled_end_at THEN
      RETURN QUERY
      SELECT r.turn_id,r.status,r.silver_reserved,r.diamonds_reserved,r.balance_silver,r.balance_diamonds
      FROM public.reserve_chat_turn(
        p_user_id,p_turn_id,p_session_id,p_user_message_id,p_assistant_message_id
      ) AS r;
      RETURN;
    END IF;
  END IF;

  IF l.status <> 'active' OR l.scheduled_end_at <= clock_timestamp() THEN
    RAISE EXCEPTION 'encounter_scene_expired_or_inactive' USING ERRCODE='23514';
  END IF;

  RETURN QUERY
  SELECT r.turn_id,r.status,r.silver_reserved,r.diamonds_reserved,r.balance_silver,r.balance_diamonds
  FROM public.reserve_chat_turn(
    p_user_id,p_turn_id,p_session_id,p_user_message_id,p_assistant_message_id
  ) AS r;
END;
$$;

REVOKE ALL ON FUNCTION public.reserve_encounter_chat_turn(uuid,uuid,uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_encounter_chat_turn(uuid,uuid,uuid,uuid,uuid) TO service_role;

COMMENT ON FUNCTION public.reserve_encounter_chat_turn(uuid,uuid,uuid,uuid,uuid) IS
  'Serializes Encounter reservations with expiry/settlement. Only matching pre-expiry reservations may recover after scene end, and only while lifecycle remains active, paused, or ready_to_settle.';
