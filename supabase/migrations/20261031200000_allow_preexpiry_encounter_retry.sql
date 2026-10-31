-- Allow recovery of a turn that was already reserved before Encounter expiry.
-- New reservations remain strictly gated by the active, unexpired lifecycle row.
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

  -- Serialize all new reservations and recovery attempts with scene settlement.
  SELECT * INTO l
  FROM public.encounter_session_lifecycle
  WHERE session_id=p_session_id
  FOR UPDATE;

  IF NOT FOUND OR l.user_id IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'encounter_scene_expired_or_inactive' USING ERRCODE='23514';
  END IF;

  -- Existing reservations are recoverable after expiry only when the original
  -- reservation was created before the scene end and every identifier matches.
  SELECT * INTO c
  FROM public.chat_turn_charges
  WHERE turn_id=p_turn_id
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

  -- No prior reservation (or only a pre-reservation 'created' row):
  -- never create a new charge after the scene expires or pauses.
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
  'Atomically serializes new Encounter reservations with scene expiry and settlement, while allowing idempotent recovery only for matching reservations created before scene end.';
