-- Story per-turn affinity + phone event persistence.
-- Additive only: no hosted project is changed by this repository migration.
-- Runtime writes are restricted to service_role RPCs; owners read phone events
-- through a narrowly scoped authenticated RPC.

CREATE TABLE IF NOT EXISTS public.story_turn_evaluations (
  turn_id uuid PRIMARY KEY REFERENCES public.chat_turn_charges(turn_id) ON DELETE CASCADE,
  session_id uuid NOT NULL REFERENCES public.chat_sessions(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  character_id uuid REFERENCES public.characters(id) ON DELETE SET NULL,
  user_message_id uuid NOT NULL REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  assistant_message_id uuid NOT NULL REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  affinity_delta integer NOT NULL DEFAULT 0 CHECK (affinity_delta BETWEEN -3 AND 3),
  reason text NOT NULL DEFAULT '' CHECK (char_length(reason) <= 280),
  phone_events jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (
    jsonb_typeof(phone_events) = 'array'
    AND jsonb_array_length(phone_events) <= 3
    AND pg_column_size(phone_events) <= 8000
  ),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'applied')),
  created_at timestamptz NOT NULL DEFAULT now(),
  applied_at timestamptz,
  CONSTRAINT story_turn_evaluations_status_check CHECK (
    (status = 'pending' AND applied_at IS NULL)
    OR (status = 'applied' AND applied_at IS NOT NULL)
  ),
  CONSTRAINT story_turn_evaluations_user_message_unique UNIQUE (user_message_id),
  CONSTRAINT story_turn_evaluations_assistant_message_unique UNIQUE (assistant_message_id)
);

CREATE INDEX IF NOT EXISTS story_turn_evaluations_pending_idx
  ON public.story_turn_evaluations (created_at)
  WHERE status = 'pending';

CREATE TABLE IF NOT EXISTS public.story_phone_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES public.chat_sessions(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  character_id uuid REFERENCES public.characters(id) ON DELETE SET NULL,
  turn_id uuid NOT NULL REFERENCES public.chat_turn_charges(turn_id) ON DELETE CASCADE,
  event_index smallint NOT NULL CHECK (event_index BETWEEN 0 AND 2),
  event_type text NOT NULL CHECK (event_type IN ('message', 'social_post', 'missed_call', 'voice_message', 'notification')),
  title text NOT NULL CHECK (char_length(title) BETWEEN 1 AND 80),
  body text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 600),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT story_phone_events_turn_index_unique UNIQUE (turn_id, event_index)
);

CREATE INDEX IF NOT EXISTS story_phone_events_session_created_idx
  ON public.story_phone_events (session_id, created_at DESC, id DESC);

ALTER TABLE public.story_turn_evaluations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.story_phone_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.story_turn_evaluations FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.story_phone_events FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.story_turn_evaluations TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.story_phone_events TO service_role;

CREATE OR REPLACE FUNCTION public.story_relationship_stage_for_affinity(p_affinity integer)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN p_affinity <= -80 THEN 'hostile'
    WHEN p_affinity <= -40 THEN 'dislike'
    WHEN p_affinity < 0 THEN 'wary'
    WHEN p_affinity < 20 THEN 'first_meeting'
    WHEN p_affinity < 45 THEN 'acquaintance'
    WHEN p_affinity < 70 THEN 'close'
    WHEN p_affinity < 90 THEN 'intimate'
    ELSE 'special'
  END;
$$;
REVOKE ALL ON FUNCTION public.story_relationship_stage_for_affinity(integer) FROM PUBLIC, anon, authenticated, service_role;

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
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role' THEN
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
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role' THEN
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
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role' THEN
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

CREATE OR REPLACE FUNCTION public.get_story_phone_events(p_session_id uuid)
RETURNS TABLE (
  id uuid,
  turn_id uuid,
  event_type text,
  title text,
  body text,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT e.id, e.turn_id, e.event_type, e.title, e.body, e.created_at
  FROM public.story_phone_events e
  JOIN public.chat_sessions s ON s.id = e.session_id
  WHERE e.session_id = p_session_id
    AND s.user_id = (SELECT auth.uid())
    AND s.chat_mode = 'story'
    AND s.deleted_at IS NULL
  ORDER BY e.created_at DESC, e.id DESC
  LIMIT 100;
$$;
REVOKE ALL ON FUNCTION public.get_story_phone_events(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_story_phone_events(uuid) TO authenticated;

COMMENT ON TABLE public.story_turn_evaluations IS
  'One idempotent structured evaluation per Story turn. Pending evaluations are applied only after the corresponding wallet charge is settled.';
COMMENT ON TABLE public.story_phone_events IS
  'Server-generated character phone events attached to a settled Story turn; readable only through the owner-checked get_story_phone_events RPC.';
