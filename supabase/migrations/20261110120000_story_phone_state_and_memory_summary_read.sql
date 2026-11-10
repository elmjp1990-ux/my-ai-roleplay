-- Separate configured phone-field snapshots from real phone-event history.
-- Existing notification rows are retained and used to seed the latest visible state.
CREATE TABLE IF NOT EXISTS public.story_phone_states (
  session_id uuid NOT NULL REFERENCES public.chat_sessions(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  character_id uuid REFERENCES public.characters(id) ON DELETE SET NULL,
  field_index smallint NOT NULL CHECK (field_index BETWEEN 0 AND 7),
  title text NOT NULL CHECK (char_length(title) BETWEEN 1 AND 80),
  body text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 600),
  source_turn_id uuid NOT NULL REFERENCES public.chat_turn_charges(turn_id) ON DELETE CASCADE,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (session_id, field_index)
);

ALTER TABLE public.story_phone_states ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.story_phone_states FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.story_phone_states TO service_role;

-- Backfill the latest notification snapshot per configured field index.
INSERT INTO public.story_phone_states (
  session_id, user_id, character_id, field_index, title, body, source_turn_id, updated_at
)
SELECT DISTINCT ON (session_id, event_index)
  session_id, user_id, character_id, event_index, title, body, turn_id, created_at
FROM public.story_phone_events
WHERE event_type = 'notification'
ORDER BY session_id, event_index, created_at DESC, id DESC
ON CONFLICT (session_id, field_index) DO UPDATE SET
  user_id = EXCLUDED.user_id,
  character_id = EXCLUDED.character_id,
  title = EXCLUDED.title,
  body = EXCLUDED.body,
  source_turn_id = EXCLUDED.source_turn_id,
  updated_at = EXCLUDED.updated_at;

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
  v_item jsonb;
  v_index integer := 0;
  v_event_type text;
  v_title text;
  v_body text;
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

  -- Remove stale state rows when the author removes configured fields.
  DELETE FROM public.story_phone_states
  WHERE session_id = v_eval.session_id
    AND field_index >= jsonb_array_length(v_eval.phone_events);

  FOR v_item IN SELECT value FROM jsonb_array_elements(v_eval.phone_events)
  LOOP
    v_event_type := COALESCE(v_item->>'event_type', '');
    v_title := COALESCE(v_item->>'title', '');
    v_body := COALESCE(v_item->>'body', '');
    IF jsonb_typeof(v_item) <> 'object'
       OR v_event_type NOT IN ('message', 'social_post', 'missed_call', 'voice_message', 'notification')
       OR char_length(v_title) NOT BETWEEN 1 AND 80
       OR char_length(v_body) NOT BETWEEN 1 AND 600 THEN
      RAISE EXCEPTION 'invalid_story_phone_event' USING ERRCODE = '22023';
    END IF;

    IF v_event_type = 'notification' THEN
      -- Author-configured status fields are snapshots: one current row per field.
      INSERT INTO public.story_phone_states (
        session_id, user_id, character_id, field_index, title, body, source_turn_id, updated_at
      ) VALUES (
        v_eval.session_id, v_eval.user_id, v_eval.character_id, v_index,
        v_title, v_body, p_turn_id, clock_timestamp()
      )
      ON CONFLICT (session_id, field_index) DO UPDATE SET
        user_id = EXCLUDED.user_id,
        character_id = EXCLUDED.character_id,
        title = EXCLUDED.title,
        body = EXCLUDED.body,
        source_turn_id = EXCLUDED.source_turn_id,
        updated_at = EXCLUDED.updated_at
      WHERE public.story_phone_states.title IS DISTINCT FROM EXCLUDED.title
         OR public.story_phone_states.body IS DISTINCT FROM EXCLUDED.body;
    ELSE
      -- This configured field is event-only in this turn; remove its old snapshot.
      DELETE FROM public.story_phone_states
      WHERE session_id = v_eval.session_id AND field_index = v_index;
      -- Genuine new communication/activity remains in the append-only event log.
      INSERT INTO public.story_phone_events (
        session_id, user_id, character_id, turn_id, event_index,
        event_type, title, body
      ) VALUES (
        v_eval.session_id, v_eval.user_id, v_eval.character_id, p_turn_id, v_index,
        v_event_type, v_title, v_body
      ) ON CONFLICT (turn_id, event_index) DO NOTHING;
    END IF;
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

CREATE OR REPLACE FUNCTION public.get_story_phone_events(p_session_id uuid)
RETURNS TABLE (id uuid, turn_id uuid, event_type text, title text, body text, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT e.id, e.turn_id, e.event_type, e.title, e.body, e.created_at
  FROM public.story_phone_events e
  JOIN public.chat_sessions s ON s.id = e.session_id
  WHERE e.session_id = p_session_id
    AND s.user_id = (SELECT auth.uid())
    AND s.chat_mode = 'story'
    AND s.deleted_at IS NULL
    AND e.event_type <> 'notification'
  ORDER BY e.created_at DESC, e.id DESC
  LIMIT 100;
$$;
REVOKE ALL ON FUNCTION public.get_story_phone_events(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_story_phone_events(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_story_phone_state(p_session_id uuid)
RETURNS TABLE (field_index smallint, title text, body text, updated_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT p.field_index, p.title, p.body, p.updated_at
  FROM public.story_phone_states p
  JOIN public.chat_sessions s ON s.id = p.session_id
  WHERE p.session_id = p_session_id
    AND s.user_id = (SELECT auth.uid())
    AND s.chat_mode = 'story'
    AND s.deleted_at IS NULL
  ORDER BY p.field_index ASC;
$$;
REVOKE ALL ON FUNCTION public.get_story_phone_state(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_story_phone_state(uuid) TO authenticated;

-- The usage ledger is service-role-only. Expose only the caller's own Story summary
-- and coarse generation state through this owner-checked RPC.
CREATE OR REPLACE FUNCTION public.get_story_memory_summary(p_session_id uuid)
RETURNS TABLE (
  summary text,
  generation_status text,
  batch_number integer,
  settled_turn_count integer,
  updated_at timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  WITH owned AS (
    SELECT s.id, s.user_id
    FROM public.chat_sessions s
    WHERE s.id = p_session_id
      AND s.user_id = (SELECT auth.uid())
      AND s.chat_mode = 'story'
      AND s.deleted_at IS NULL
  ), counts AS (
    SELECT count(*)::integer AS settled_count
    FROM public.chat_turn_charges c
    JOIN owned o ON o.id = c.session_id AND o.user_id = c.user_id
    WHERE c.status = 'settled'
  ), latest_attempt AS (
    SELECT u.status, u.batch_number, u.processed_at, u.created_at
    FROM public.ai_model_usage u
    JOIN owned o ON o.id = u.session_id AND o.user_id = u.user_id
    WHERE u.generation_type = 'memory_summary'
    ORDER BY u.batch_number DESC
    LIMIT 1
  ), latest_completed AS (
    SELECT u.summary, u.batch_number, u.processed_at
    FROM public.ai_model_usage u
    JOIN owned o ON o.id = u.session_id AND o.user_id = u.user_id
    WHERE u.generation_type = 'memory_summary' AND u.status = 'completed'
    ORDER BY u.batch_number DESC
    LIMIT 1
  )
  SELECT
    (SELECT l.summary FROM latest_completed l),
    COALESCE((SELECT l.status FROM latest_attempt l), CASE WHEN c.settled_count >= 5 THEN 'pending' ELSE 'collecting' END),
    COALESCE((SELECT l.batch_number FROM latest_attempt l), (SELECT l.batch_number FROM latest_completed l)),
    c.settled_count,
    COALESCE((SELECT l.processed_at FROM latest_attempt l), (SELECT l.created_at FROM latest_attempt l), (SELECT l.processed_at FROM latest_completed l))
  FROM counts c
  WHERE EXISTS (SELECT 1 FROM owned);
$$;
REVOKE ALL ON FUNCTION public.get_story_memory_summary(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_story_memory_summary(uuid) TO authenticated;

