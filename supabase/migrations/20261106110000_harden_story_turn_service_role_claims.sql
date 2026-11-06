-- Harden the service-role guard for both legacy scalar and modern JSON JWT claims.
CREATE OR REPLACE FUNCTION public.is_service_role_request()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  v_role text;
  v_claims text;
BEGIN
  v_role := NULLIF(current_setting('request.jwt.claim.role', true), '');
  IF v_role IS NOT NULL THEN
    RETURN v_role = 'service_role';
  END IF;

  v_claims := NULLIF(current_setting('request.jwt.claims', true), '');
  IF v_claims IS NULL THEN
    RETURN false;
  END IF;

  BEGIN
    v_role := v_claims::jsonb ->> 'role';
  EXCEPTION WHEN others THEN
    RETURN false;
  END;

  RETURN v_role = 'service_role';
END;
$$;
REVOKE ALL ON FUNCTION public.is_service_role_request() FROM PUBLIC, anon, authenticated, service_role;

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
     OR jsonb_array_length(COALESCE(p_phone_events, '[]'::jsonb)) > 3
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
     OR v_charge.assistant_message_id IS DISTINCT FROM p_assistant_message_id
     OR v_charge.status NOT IN ('needs_reconciliation', 'settled') THEN
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

CREATE OR REPLACE FUNCTION public.apply_story_turn_evaluation(p_turn_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_eval public.story_turn_evaluations%ROWTYPE;
  v_charge public.chat_turn_charges%ROWTYPE;
  v_state public.story_relationship_states%ROWTYPE;
  v_affinity integer;
  v_event jsonb;
  v_index integer := 0;
BEGIN
  IF NOT public.is_service_role_request() THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_eval FROM public.story_turn_evaluations
  WHERE turn_id = p_turn_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'not_queued');
  END IF;
  IF v_eval.status = 'applied' THEN
    SELECT affinity INTO v_affinity FROM public.story_relationship_states
    WHERE session_id = v_eval.session_id;
    RETURN jsonb_build_object('status', 'applied', 'idempotent', true, 'affinity', v_affinity);
  END IF;

  SELECT * INTO v_charge FROM public.chat_turn_charges
  WHERE turn_id = p_turn_id FOR KEY SHARE;
  IF NOT FOUND OR v_charge.status <> 'settled' THEN
    RETURN jsonb_build_object('status', 'waiting_for_settlement');
  END IF;

  SELECT * INTO v_state FROM public.story_relationship_states
  WHERE session_id = v_eval.session_id AND user_id = v_eval.user_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'story_relationship_state_missing' USING ERRCODE = '23503';
  END IF;

  v_affinity := GREATEST(-100, LEAST(100, v_state.affinity + v_eval.affinity_delta));
  UPDATE public.story_relationship_states
  SET affinity = v_affinity,
      relationship_stage = CASE WHEN v_eval.affinity_delta = 0 THEN v_state.relationship_stage ELSE public.story_relationship_stage_for_affinity(v_affinity) END,
      turn_count_since_summary = mod(turn_count_since_summary + 1, 5),
      updated_at = clock_timestamp()
  WHERE session_id = v_eval.session_id;

  FOR v_event IN SELECT value FROM jsonb_array_elements(v_eval.phone_events)
  LOOP
    IF jsonb_typeof(v_event) <> 'object'
       OR COALESCE(v_event->>'event_type', '') NOT IN ('message', 'social_post', 'missed_call', 'voice_message', 'notification')
       OR char_length(COALESCE(v_event->>'title', '')) NOT BETWEEN 1 AND 80
       OR char_length(COALESCE(v_event->>'body', '')) NOT BETWEEN 1 AND 600 THEN
      RAISE EXCEPTION 'invalid_story_phone_event' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.story_phone_events (
      session_id, user_id, character_id, turn_id, event_index,
      event_type, title, body
    ) VALUES (
      v_eval.session_id, v_eval.user_id, v_eval.character_id, p_turn_id, v_index,
      v_event->>'event_type', v_event->>'title', v_event->>'body'
    ) ON CONFLICT (turn_id, event_index) DO NOTHING;
    v_index := v_index + 1;
  END LOOP;

  UPDATE public.story_turn_evaluations
  SET status = 'applied', applied_at = clock_timestamp()
  WHERE turn_id = p_turn_id;

  RETURN jsonb_build_object('status', 'applied', 'idempotent', false, 'affinity', v_affinity);
END;
$$;

REVOKE ALL ON FUNCTION public.apply_story_turn_evaluation(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_story_turn_evaluation(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.complete_story_relationship_batch(
  p_session_id uuid,
  p_user_id uuid,
  p_character_id uuid,
  p_batch_number integer,
  p_source_turn_ids uuid[],
  p_summary text,
  p_affinity_delta integer,
  p_evaluation jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_state public.story_relationship_states%ROWTYPE;
  v_existing public.story_relationship_batches%ROWTYPE;
  v_source_count integer;
  v_affinity integer;
BEGIN
  IF NOT public.is_service_role_request() THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF p_batch_number < 1 OR cardinality(p_source_turn_ids) <> 5
     OR p_affinity_delta NOT BETWEEN -5 AND 5
     OR char_length(COALESCE(p_summary, '')) NOT BETWEEN 1 AND 2000
     OR jsonb_typeof(COALESCE(p_evaluation, '{}'::jsonb)) <> 'object'
     OR pg_column_size(COALESCE(p_evaluation, '{}'::jsonb)) > 12000 THEN
    RAISE EXCEPTION 'invalid_story_relationship_batch' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_state FROM public.story_relationship_states
  WHERE session_id = p_session_id AND user_id = p_user_id
    AND character_id IS NOT DISTINCT FROM p_character_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'story_relationship_state_missing' USING ERRCODE = '23503';
  END IF;

  SELECT count(*) INTO v_source_count
  FROM public.chat_turn_charges c
  WHERE c.turn_id = ANY(p_source_turn_ids)
    AND c.session_id = p_session_id
    AND c.user_id = p_user_id
    AND c.status = 'settled';
  IF v_source_count <> 5 THEN
    RAISE EXCEPTION 'story_relationship_batch_sources_invalid' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO v_existing FROM public.story_relationship_batches
  WHERE session_id = p_session_id AND batch_number = p_batch_number
  FOR UPDATE;
  IF FOUND AND v_existing.status = 'completed' THEN
    RETURN jsonb_build_object('status', 'completed', 'idempotent', true, 'affinity', v_state.affinity);
  END IF;

  v_affinity := GREATEST(-100, LEAST(100, v_state.affinity + p_affinity_delta));
  INSERT INTO public.story_relationship_batches (
    session_id, user_id, character_id, batch_number,
    first_turn_number, last_turn_number, source_turn_ids,
    status, summary, affinity_delta, evaluation, processed_at
  ) VALUES (
    p_session_id, p_user_id, p_character_id, p_batch_number,
    (p_batch_number - 1) * 5 + 1, p_batch_number * 5, p_source_turn_ids,
    'completed', p_summary, p_affinity_delta, COALESCE(p_evaluation, '{}'::jsonb), clock_timestamp()
  )
  ON CONFLICT (session_id, batch_number) DO UPDATE SET
    source_turn_ids = EXCLUDED.source_turn_ids,
    status = 'completed',
    summary = EXCLUDED.summary,
    affinity_delta = EXCLUDED.affinity_delta,
    evaluation = EXCLUDED.evaluation,
    processed_at = EXCLUDED.processed_at;

  UPDATE public.story_relationship_states
  SET affinity = v_affinity,
      relationship_stage = CASE WHEN p_affinity_delta = 0 THEN v_state.relationship_stage ELSE public.story_relationship_stage_for_affinity(v_affinity) END,
      last_processed_batch = GREATEST(last_processed_batch, p_batch_number),
      turn_count_since_summary = 0,
      updated_at = clock_timestamp()
  WHERE session_id = p_session_id;

  RETURN jsonb_build_object('status', 'completed', 'idempotent', false, 'affinity', v_affinity);
END;
$$;

REVOKE ALL ON FUNCTION public.complete_story_relationship_batch(
  uuid, uuid, uuid, integer, uuid[], text, integer, jsonb
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_story_relationship_batch(
  uuid, uuid, uuid, integer, uuid[], text, integer, jsonb
) TO service_role;

