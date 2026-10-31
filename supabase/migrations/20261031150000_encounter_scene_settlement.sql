-- Atomic, due-gated Encounter scene settlement.
-- The evaluator runs outside SQL; this RPC only commits a validated result once.
CREATE OR REPLACE FUNCTION public.settle_encounter_session(
  p_session_id uuid,
  p_affinity_delta integer,
  p_relationship_stage text,
  p_memories jsonb DEFAULT '[]'::jsonb,
  p_evaluation jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  l public.encounter_session_lifecycle%ROWTYPE;
  v_current integer := 0;
  v_final integer := 0;
  v_state_id uuid;
  v_result jsonb;
BEGIN
  IF p_session_id IS NULL
     OR p_affinity_delta IS NULL OR p_affinity_delta NOT BETWEEN -100 AND 100
     OR p_relationship_stage NOT IN ('hostile','dislike','wary','first_meeting','acquaintance','close','intimate','special')
     OR jsonb_typeof(COALESCE(p_memories,'[]'::jsonb)) <> 'array'
     OR pg_column_size(COALESCE(p_memories,'[]'::jsonb)) > 20000
     OR jsonb_typeof(COALESCE(p_evaluation,'{}'::jsonb)) <> 'object'
     OR pg_column_size(COALESCE(p_evaluation,'{}'::jsonb)) > 12000 THEN
    RAISE EXCEPTION 'Invalid Encounter settlement payload' USING ERRCODE='22023';
  END IF;

  SELECT * INTO l
  FROM public.encounter_session_lifecycle
  WHERE session_id=p_session_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Encounter lifecycle not found' USING ERRCODE='P0002';
  END IF;

  -- Idempotent retry: return the committed result without applying affinity twice.
  IF l.status='settled' THEN
    RETURN jsonb_build_object('settled',true,'idempotent',true,'result',l.settlement_result);
  END IF;

  IF l.character_id IS NULL THEN
    RAISE EXCEPTION 'Encounter character is no longer available for relationship settlement' USING ERRCODE='23514';
  END IF;

  IF l.status NOT IN ('active','paused','ready_to_settle') THEN
    RAISE EXCEPTION 'Encounter lifecycle is not settleable' USING ERRCODE='23514';
  END IF;
  IF l.scheduled_end_at > now() THEN
    RAISE EXCEPTION 'Encounter scene has not reached scheduled end' USING ERRCODE='23514';
  END IF;

  -- Reconcile only evidence rows that have actually been persisted from settled charges.
  IF (SELECT count(*) FROM public.encounter_session_turns t WHERE t.session_id=p_session_id) <> l.turn_count THEN
    RAISE EXCEPTION 'Encounter turn evidence is incomplete' USING ERRCODE='23514';
  END IF;

  INSERT INTO public.encounter_character_state(user_id,character_id,affinity,relationship_stage,first_met_at,last_interaction_at)
  VALUES(l.user_id,l.character_id,0,'first_meeting',now(),now())
  ON CONFLICT (user_id,character_id) DO NOTHING;

  SELECT s.id,s.affinity
    INTO v_state_id,v_current
  FROM public.encounter_character_state s
  WHERE s.user_id=l.user_id AND s.character_id=l.character_id
  FOR UPDATE;

  v_final := greatest(-100,least(100,v_current+p_affinity_delta));

  UPDATE public.encounter_character_state
  SET affinity=v_final,
      relationship_stage=p_relationship_stage,
      last_interaction_at=now(),
      updated_at=now()
  WHERE id=v_state_id;

  v_result := jsonb_build_object(
    'final_affinity',v_final,
    'affinity_delta',v_final-v_current,
    'relationship_stage',p_relationship_stage,
    'memories',COALESCE(p_memories,'[]'::jsonb),
    'evaluation',COALESCE(p_evaluation,'{}'::jsonb),
    'turn_count',l.turn_count,
    'source_session_id',p_session_id
  );

  UPDATE public.encounter_session_lifecycle
  SET status='settled',
      settlement_delta=v_final-v_current,
      settlement_result=v_result,
      settled_at=now(),
      updated_at=now()
  WHERE session_id=p_session_id;

  RETURN jsonb_build_object('settled',true,'idempotent',false,'result',v_result);
END;
$$;

REVOKE ALL ON FUNCTION public.settle_encounter_session(uuid,integer,text,jsonb,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.settle_encounter_session(uuid,integer,text,jsonb,jsonb) TO service_role;

COMMENT ON FUNCTION public.settle_encounter_session(uuid,integer,text,jsonb,jsonb) IS
  'Commits an externally evaluated Encounter result once, only after scheduled_end_at. Paused sessions are eligible after expiry; retries return the immutable committed result.';
