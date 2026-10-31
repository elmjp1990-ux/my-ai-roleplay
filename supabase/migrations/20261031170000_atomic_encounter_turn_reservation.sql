-- Serialize Encounter scene validity with wallet reservation.
-- Locking the lifecycle row makes expiry/settlement and turn reservation mutually exclusive.
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
BEGIN
  IF p_user_id IS NULL OR p_turn_id IS NULL OR p_session_id IS NULL
     OR p_user_message_id IS NULL OR p_assistant_message_id IS NULL THEN
    RAISE EXCEPTION 'invalid_turn_request' USING ERRCODE='22023';
  END IF;

  SELECT * INTO l
  FROM public.encounter_session_lifecycle
  WHERE session_id=p_session_id
  FOR UPDATE;

  IF NOT FOUND
     OR l.user_id IS DISTINCT FROM p_user_id
     OR l.status <> 'active'
     OR l.scheduled_end_at <= clock_timestamp() THEN
    RAISE EXCEPTION 'encounter_scene_expired_or_inactive' USING ERRCODE='23514';
  END IF;

  -- The lifecycle row lock remains held until this transaction commits,
  -- so settlement cannot pass this turn reservation concurrently.
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
  'Atomically locks the active Encounter lifecycle, validates its unexpired scene window, and reserves wallet funds in the same transaction.';

-- Use wall-clock time after acquiring the lifecycle lock, not transaction-start now().
CREATE OR REPLACE FUNCTION public.record_encounter_session_turn_evidence(
  p_turn_id uuid,p_session_id uuid,p_user_id uuid,p_character_id uuid,
  p_user_message_id uuid,p_assistant_message_id uuid,p_evaluation jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  l public.encounter_session_lifecycle%ROWTYPE;
  c public.chat_turn_charges%ROWTYPE;
  um public.chat_messages%ROWTYPE;
  am public.chat_messages%ROWTYPE;
  oldrow public.encounter_session_turns%ROWTYPE;
  n integer;
BEGIN
  IF p_turn_id IS NULL OR p_session_id IS NULL OR p_user_id IS NULL
     OR p_character_id IS NULL OR p_user_message_id IS NULL OR p_assistant_message_id IS NULL
     OR jsonb_typeof(COALESCE(p_evaluation,'{}'::jsonb)) <> 'object'
     OR pg_column_size(COALESCE(p_evaluation,'{}'::jsonb)) > 8000 THEN
    RAISE EXCEPTION 'Invalid evidence input' USING ERRCODE='22023';
  END IF;

  SELECT * INTO l FROM public.encounter_session_lifecycle
  WHERE session_id=p_session_id FOR UPDATE;

  IF NOT FOUND OR l.user_id IS DISTINCT FROM p_user_id
     OR l.character_id IS DISTINCT FROM p_character_id
     OR l.status <> 'active' OR l.scheduled_end_at <= clock_timestamp() THEN
    RAISE EXCEPTION 'Invalid or expired Encounter lifecycle' USING ERRCODE='23514';
  END IF;

  SELECT * INTO c FROM public.chat_turn_charges WHERE turn_id=p_turn_id FOR SHARE;
  IF NOT FOUND OR c.session_id IS DISTINCT FROM p_session_id
     OR c.user_id IS DISTINCT FROM p_user_id OR c.status <> 'settled'
     OR c.user_message_id IS DISTINCT FROM p_user_message_id
     OR c.assistant_message_id IS DISTINCT FROM p_assistant_message_id
     OR c.expected_assistant_message_id IS DISTINCT FROM p_assistant_message_id THEN
    RAISE EXCEPTION 'Charge evidence mismatch or unsettled' USING ERRCODE='23514';
  END IF;

  SELECT * INTO um FROM public.chat_messages WHERE id=p_user_message_id FOR SHARE;
  IF NOT FOUND OR um.session_id IS DISTINCT FROM p_session_id OR um.role <> 'user'
     OR um.deleted_at IS NOT NULL OR length(btrim(um.content))=0 THEN
    RAISE EXCEPTION 'Invalid user message evidence' USING ERRCODE='23514';
  END IF;

  SELECT * INTO am FROM public.chat_messages WHERE id=p_assistant_message_id FOR SHARE;
  IF NOT FOUND OR am.session_id IS DISTINCT FROM p_session_id OR am.role <> 'assistant'
     OR am.deleted_at IS NOT NULL OR length(btrim(am.content))=0 THEN
    RAISE EXCEPTION 'Invalid assistant message evidence' USING ERRCODE='23514';
  END IF;

  SELECT * INTO oldrow FROM public.encounter_session_turns WHERE turn_id=p_turn_id;
  IF FOUND THEN
    IF oldrow.session_id IS DISTINCT FROM p_session_id
       OR oldrow.user_id IS DISTINCT FROM p_user_id
       OR oldrow.character_id IS DISTINCT FROM p_character_id
       OR oldrow.user_message_id IS DISTINCT FROM p_user_message_id
       OR oldrow.assistant_message_id IS DISTINCT FROM p_assistant_message_id THEN
      RAISE EXCEPTION 'Evidence idempotency collision' USING ERRCODE='23505';
    END IF;
    RETURN jsonb_build_object('turn_id',oldrow.turn_id,'turn_number',oldrow.turn_number,
      'status',oldrow.evaluation_status,'idempotent',true);
  END IF;

  n := l.turn_count+1;
  INSERT INTO public.encounter_session_turns(
    turn_id,session_id,user_id,character_id,user_message_id,assistant_message_id,
    turn_number,evaluation_status,evaluation
  ) VALUES (
    p_turn_id,p_session_id,p_user_id,p_character_id,p_user_message_id,p_assistant_message_id,
    n,'pending',COALESCE(p_evaluation,'{}'::jsonb)
  );

  UPDATE public.encounter_session_lifecycle SET turn_count=n,updated_at=clock_timestamp()
  WHERE session_id=p_session_id;

  RETURN jsonb_build_object('turn_id',p_turn_id,'turn_number',n,'status','pending','idempotent',false);
END;
$$;

REVOKE ALL ON FUNCTION public.record_encounter_session_turn_evidence(uuid,uuid,uuid,uuid,uuid,uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.record_encounter_session_turn_evidence(uuid,uuid,uuid,uuid,uuid,uuid,jsonb) TO service_role;

-- Settlement uses the wall clock after acquiring its lifecycle row lock.
CREATE OR REPLACE FUNCTION public.settle_encounter_session(
  p_session_id uuid,p_affinity_delta integer,p_relationship_stage text,
  p_memories jsonb DEFAULT '[]'::jsonb,p_evaluation jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  l public.encounter_session_lifecycle%ROWTYPE;
  v_current integer := 0;
  v_final integer := 0;
  v_state_id uuid;
  v_result jsonb;
BEGIN
  IF p_session_id IS NULL OR p_affinity_delta IS NULL
     OR p_affinity_delta NOT BETWEEN -100 AND 100
     OR p_relationship_stage NOT IN ('hostile','dislike','wary','first_meeting','acquaintance','close','intimate','special')
     OR jsonb_typeof(COALESCE(p_memories,'[]'::jsonb)) <> 'array'
     OR pg_column_size(COALESCE(p_memories,'[]'::jsonb)) > 20000
     OR jsonb_typeof(COALESCE(p_evaluation,'{}'::jsonb)) <> 'object'
     OR pg_column_size(COALESCE(p_evaluation,'{}'::jsonb)) > 12000 THEN
    RAISE EXCEPTION 'Invalid Encounter settlement payload' USING ERRCODE='22023';
  END IF;

  SELECT * INTO l FROM public.encounter_session_lifecycle
  WHERE session_id=p_session_id FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Encounter lifecycle not found' USING ERRCODE='P0002'; END IF;

  IF l.status='settled' THEN
    RETURN jsonb_build_object('settled',true,'idempotent',true,'result',l.settlement_result);
  END IF;

  IF l.character_id IS NULL THEN
    RAISE EXCEPTION 'Encounter character is no longer available for relationship settlement' USING ERRCODE='23514';
  END IF;

  IF l.status NOT IN ('active','paused','ready_to_settle')
     OR l.scheduled_end_at > clock_timestamp() THEN
    RAISE EXCEPTION 'Encounter scene has not reached scheduled end or is not settleable' USING ERRCODE='23514';
  END IF;

  IF (SELECT count(*) FROM public.encounter_session_turns t WHERE t.session_id=p_session_id) <> l.turn_count THEN
    RAISE EXCEPTION 'Encounter turn evidence is incomplete' USING ERRCODE='23514';
  END IF;

  INSERT INTO public.encounter_character_state(user_id,character_id,affinity,relationship_stage,first_met_at,last_interaction_at)
  VALUES(l.user_id,l.character_id,0,'first_meeting',clock_timestamp(),clock_timestamp())
  ON CONFLICT (user_id,character_id) DO NOTHING;

  SELECT s.id,s.affinity INTO v_state_id,v_current
  FROM public.encounter_character_state s
  WHERE s.user_id=l.user_id AND s.character_id=l.character_id FOR UPDATE;

  v_final := greatest(-100,least(100,v_current+p_affinity_delta));

  UPDATE public.encounter_character_state
  SET affinity=v_final,relationship_stage=p_relationship_stage,
      last_interaction_at=clock_timestamp(),updated_at=clock_timestamp()
  WHERE id=v_state_id;

  v_result := jsonb_build_object(
    'final_affinity',v_final,'affinity_delta',v_final-v_current,
    'relationship_stage',p_relationship_stage,'memories',COALESCE(p_memories,'[]'::jsonb),
    'evaluation',COALESCE(p_evaluation,'{}'::jsonb),'turn_count',l.turn_count,
    'source_session_id',p_session_id
  );

  UPDATE public.encounter_session_lifecycle
  SET status='settled',settlement_delta=v_final-v_current,
      settlement_result=v_result,settled_at=clock_timestamp(),updated_at=clock_timestamp()
  WHERE session_id=p_session_id;

  RETURN jsonb_build_object('settled',true,'idempotent',false,'result',v_result);
END;
$$;

REVOKE ALL ON FUNCTION public.settle_encounter_session(uuid,integer,text,jsonb,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.settle_encounter_session(uuid,integer,text,jsonb,jsonb) TO service_role;
