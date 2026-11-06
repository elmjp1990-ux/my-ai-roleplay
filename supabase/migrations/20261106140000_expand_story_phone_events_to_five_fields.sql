-- Five author-configured phone fields are regenerated as one coherent state snapshot per Story turn.
-- Existing settled events remain intact; only the allowed per-turn field count expands.
ALTER TABLE public.story_turn_evaluations
  DROP CONSTRAINT IF EXISTS story_turn_evaluations_phone_events_check;
ALTER TABLE public.story_turn_evaluations
  ADD CONSTRAINT story_turn_evaluations_phone_events_check CHECK (
    jsonb_typeof(phone_events) = 'array'
    AND jsonb_array_length(phone_events) <= 5
    AND pg_column_size(phone_events) <= 8000
  );

ALTER TABLE public.story_phone_events
  DROP CONSTRAINT IF EXISTS story_phone_events_event_index_check;
ALTER TABLE public.story_phone_events
  ADD CONSTRAINT story_phone_events_event_index_check CHECK (event_index BETWEEN 0 AND 4);

CREATE OR REPLACE FUNCTION public.queue_story_turn_evaluation(
  p_turn_id uuid,
  p_session_id uuid,
  p_user_id uuid,
  p_character_id uuid,
  p_user_message_id uuid,
  p_assistant_message_id uuid,
  p_affinity_delta integer,
  p_reason text,
  p_phone_events jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_charge public.chat_turn_charges%ROWTYPE;
  v_session public.chat_sessions%ROWTYPE;
  v_user_role text;
  v_assistant_role text;
  v_existing public.story_turn_evaluations%ROWTYPE;
BEGIN
  IF NOT public.is_service_role_request() THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF p_affinity_delta IS NULL OR p_affinity_delta NOT BETWEEN -3 AND 3
     OR char_length(COALESCE(p_reason, '')) > 280
     OR jsonb_typeof(COALESCE(p_phone_events, '[]'::jsonb)) <> 'array'
     OR jsonb_array_length(COALESCE(p_phone_events, '[]'::jsonb)) > 5
     OR pg_column_size(COALESCE(p_phone_events, '[]'::jsonb)) > 8000 THEN
    RAISE EXCEPTION 'invalid_story_turn_evaluation' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_session FROM public.chat_sessions WHERE id = p_session_id FOR KEY SHARE;
  IF NOT FOUND OR v_session.user_id IS DISTINCT FROM p_user_id
     OR v_session.character_id IS DISTINCT FROM p_character_id
     OR v_session.chat_mode <> 'story' OR v_session.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'story_session_owner_or_mode_mismatch' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO v_charge FROM public.chat_turn_charges
  WHERE turn_id = p_turn_id FOR KEY SHARE;
  IF NOT FOUND OR v_charge.session_id IS DISTINCT FROM p_session_id
     OR v_charge.user_id IS DISTINCT FROM p_user_id
     OR v_charge.user_message_id IS DISTINCT FROM p_user_message_id
     OR v_charge.expected_assistant_message_id IS DISTINCT FROM p_assistant_message_id
     OR (v_charge.assistant_message_id IS NOT NULL
         AND v_charge.assistant_message_id IS DISTINCT FROM p_assistant_message_id)
     OR v_charge.status NOT IN ('reserved', 'needs_reconciliation', 'settled') THEN
    RAISE EXCEPTION 'story_turn_charge_evidence_mismatch' USING ERRCODE = '23514';
  END IF;

  SELECT role INTO v_user_role FROM public.chat_messages
  WHERE id = p_user_message_id AND session_id = p_session_id;
  SELECT role INTO v_assistant_role FROM public.chat_messages
  WHERE id = p_assistant_message_id AND session_id = p_session_id;
  IF v_user_role IS DISTINCT FROM 'user' OR v_assistant_role IS DISTINCT FROM 'assistant' THEN
    RAISE EXCEPTION 'story_turn_message_evidence_mismatch' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO v_existing FROM public.story_turn_evaluations
  WHERE turn_id = p_turn_id FOR UPDATE;
  IF FOUND THEN
    IF v_existing.session_id IS DISTINCT FROM p_session_id
       OR v_existing.user_id IS DISTINCT FROM p_user_id
       OR v_existing.user_message_id IS DISTINCT FROM p_user_message_id
       OR v_existing.assistant_message_id IS DISTINCT FROM p_assistant_message_id
       OR v_existing.affinity_delta IS DISTINCT FROM p_affinity_delta
       OR v_existing.reason IS DISTINCT FROM COALESCE(p_reason, '')
       OR v_existing.phone_events IS DISTINCT FROM COALESCE(p_phone_events, '[]'::jsonb) THEN
      RAISE EXCEPTION 'story_turn_evaluation_idempotency_conflict' USING ERRCODE = '23505';
    END IF;
    RETURN jsonb_build_object('status', v_existing.status, 'idempotent', true);
  END IF;

  INSERT INTO public.story_turn_evaluations (
    turn_id, session_id, user_id, character_id, user_message_id,
    assistant_message_id, affinity_delta, reason, phone_events
  ) VALUES (
    p_turn_id, p_session_id, p_user_id, p_character_id, p_user_message_id,
    p_assistant_message_id, p_affinity_delta, COALESCE(p_reason, ''),
    COALESCE(p_phone_events, '[]'::jsonb)
  );
  RETURN jsonb_build_object('status', 'pending', 'idempotent', false);
END;
$$;

REVOKE ALL ON FUNCTION public.queue_story_turn_evaluation(
  uuid, uuid, uuid, uuid, uuid, uuid, integer, text, jsonb
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.queue_story_turn_evaluation(
  uuid, uuid, uuid, uuid, uuid, uuid, integer, text, jsonb
) TO service_role;
