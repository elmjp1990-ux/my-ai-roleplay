-- DRAFT ONLY — PR #200 Encounter/session deletion lifecycle guards.
-- Reviewed against the connected test project's live function definitions on 2026-11-01.
-- Do not apply to a hosted database until migration provenance and local replay are fixed.
--
-- Closes four lifecycle gaps:
-- 1. Latest-settled Encounter read RPCs must not return deleted chat sessions.
-- 2. Encounter pause/resume and settlement must lock the chat_sessions parent first
--    and reject a deleted session, serializing with chat deletion.
-- 3. Session-link triggers must reject new/reassigned lifecycle/evidence/story rows
--    for deleted sessions and lock the parent first.
-- 4. Encounter diary rows linked through metadata.session_id must become unreadable
--    immediately after parent chat deletion (separate policy draft file).

CREATE OR REPLACE FUNCTION public.get_latest_settled_encounter_affinity(
  p_character_id uuid
)
RETURNS TABLE(
  session_id uuid,
  settled_at timestamptz,
  affinity integer,
  relationship_stage text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  IF p_character_id IS NULL THEN
    RAISE EXCEPTION 'Character ID is required' USING ERRCODE='22023';
  END IF;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501';
  END IF;

  RETURN QUERY
  SELECT lifecycle.session_id,
         lifecycle.settled_at,
         (lifecycle.settlement_result->>'final_affinity')::integer,
         lifecycle.settlement_result->>'relationship_stage'
  FROM public.encounter_session_lifecycle AS lifecycle
  JOIN public.chat_sessions AS session
    ON session.id = lifecycle.session_id
   AND session.user_id = v_user_id
   AND session.chat_mode = 'encounter'
   AND session.deleted_at IS NULL
  WHERE lifecycle.user_id = v_user_id
    AND lifecycle.character_id = p_character_id
    AND lifecycle.status = 'settled'
    AND lifecycle.settled_at IS NOT NULL
    AND jsonb_typeof(lifecycle.settlement_result) = 'object'
    AND (lifecycle.settlement_result->>'final_affinity') ~ '^-?[0-9]{1,3}$'
    AND (lifecycle.settlement_result->>'final_affinity')::integer BETWEEN -100 AND 100
    AND lifecycle.settlement_result->>'relationship_stage' IN (
      'hostile','dislike','wary','first_meeting',
      'acquaintance','close','intimate','special'
    )
  ORDER BY lifecycle.settled_at DESC, lifecycle.session_id
  LIMIT 1;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_latest_settled_encounter_session(
  p_character_id uuid
)
RETURNS TABLE(
  session_id uuid,
  settled_at timestamptz,
  relationship_stage text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  IF p_character_id IS NULL THEN
    RAISE EXCEPTION 'Character ID is required' USING ERRCODE='22023';
  END IF;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501';
  END IF;

  RETURN QUERY
  SELECT lifecycle.session_id,
         lifecycle.settled_at,
         lifecycle.settlement_result->>'relationship_stage'
  FROM public.encounter_session_lifecycle AS lifecycle
  JOIN public.chat_sessions AS session
    ON session.id = lifecycle.session_id
   AND session.user_id = v_user_id
   AND session.chat_mode = 'encounter'
   AND session.deleted_at IS NULL
  WHERE lifecycle.user_id = v_user_id
    AND lifecycle.character_id = p_character_id
    AND lifecycle.status = 'settled'
    AND lifecycle.settled_at IS NOT NULL
    AND jsonb_typeof(lifecycle.settlement_result) = 'object'
    AND (lifecycle.settlement_result->>'final_affinity') ~ '^-?[0-9]{1,3}$'
    AND (lifecycle.settlement_result->>'final_affinity')::integer BETWEEN -100 AND 100
    AND lifecycle.settlement_result->>'relationship_stage' IN (
      'hostile','dislike','wary','first_meeting',
      'acquaintance','close','intimate','special'
    )
  ORDER BY lifecycle.settled_at DESC, lifecycle.session_id
  LIMIT 1;
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_encounter_session_lifecycle_state(
  p_session_id uuid,
  p_user_id uuid,
  p_action text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  l public.encounter_session_lifecycle%ROWTYPE;
  v_status text;
BEGIN
  IF p_session_id IS NULL OR p_user_id IS NULL
     OR p_action NOT IN ('pause','resume') THEN
    RAISE EXCEPTION 'Invalid Encounter lifecycle state request' USING ERRCODE='22023';
  END IF;

  -- Parent-first lock matches chat deletion and turn writers.
  PERFORM 1
  FROM public.chat_sessions AS s
  WHERE s.id = p_session_id
    AND s.user_id = p_user_id
    AND s.chat_mode = 'encounter'
    AND s.deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Encounter session is deleted or inaccessible' USING ERRCODE='42501';
  END IF;

  SELECT * INTO l
  FROM public.encounter_session_lifecycle
  WHERE session_id = p_session_id
  FOR UPDATE;

  IF NOT FOUND OR l.user_id IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'Encounter session not found' USING ERRCODE='P0002';
  END IF;
  IF l.character_id IS NULL THEN
    RAISE EXCEPTION 'Encounter character is unavailable' USING ERRCODE='23514';
  END IF;
  IF l.status = 'settled' OR l.status = 'cancelled'
     OR l.scheduled_end_at <= clock_timestamp() THEN
    RAISE EXCEPTION 'Encounter scene expired or closed' USING ERRCODE='23514';
  END IF;

  IF p_action = 'pause' THEN
    IF l.status = 'paused' THEN
      RETURN jsonb_build_object('session_id',p_session_id,'status','paused','idempotent',true);
    END IF;
    IF l.status <> 'active' THEN
      RAISE EXCEPTION 'Encounter session cannot be paused from current state' USING ERRCODE='23514';
    END IF;
    v_status := 'paused';
  ELSE
    IF l.status = 'active' THEN
      RETURN jsonb_build_object('session_id',p_session_id,'status','active','idempotent',true);
    END IF;
    IF l.status <> 'paused' THEN
      RAISE EXCEPTION 'Encounter session cannot be resumed from current state' USING ERRCODE='23514';
    END IF;
    v_status := 'active';
  END IF;

  UPDATE public.encounter_session_lifecycle
  SET status = v_status, updated_at = clock_timestamp()
  WHERE session_id = p_session_id;

  RETURN jsonb_build_object('session_id',p_session_id,'status',v_status,'idempotent',false);
END;
$function$;

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
SET search_path TO ''
AS $function$
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

  -- Lock and validate the parent before lifecycle/relationship rows. This makes
  -- settlement serialize with delete_chat_session_content on the same session.
  PERFORM 1
  FROM public.chat_sessions AS s
  WHERE s.id = p_session_id
    AND s.chat_mode = 'encounter'
    AND s.deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Encounter session is deleted or inaccessible' USING ERRCODE='23514';
  END IF;

  SELECT * INTO l
  FROM public.encounter_session_lifecycle
  WHERE session_id = p_session_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Encounter lifecycle not found' USING ERRCODE='P0002';
  END IF;
  IF l.status = 'settled' THEN
    RETURN jsonb_build_object('settled',true,'idempotent',true,'result',l.settlement_result);
  END IF;
  IF l.character_id IS NULL THEN
    RAISE EXCEPTION 'Encounter character is no longer available for relationship settlement' USING ERRCODE='23514';
  END IF;
  IF l.status NOT IN ('active','paused','ready_to_settle')
     OR l.scheduled_end_at > clock_timestamp() THEN
    RAISE EXCEPTION 'Encounter scene has not reached scheduled end or is not settleable' USING ERRCODE='23514';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.chat_turn_charges AS c
    WHERE c.session_id = p_session_id
      AND c.reserved_at IS NOT NULL
      AND c.reserved_at <= l.scheduled_end_at
      AND c.status IN ('reserved','needs_reconciliation')
  ) THEN
    RAISE EXCEPTION 'Encounter has pending pre-expiry turns' USING ERRCODE='23514';
  END IF;

  IF (SELECT count(*) FROM public.encounter_session_turns AS t
      WHERE t.session_id = p_session_id) <> l.turn_count THEN
    RAISE EXCEPTION 'Encounter turn evidence is incomplete' USING ERRCODE='23514';
  END IF;

  INSERT INTO public.encounter_character_state(
    user_id,character_id,affinity,relationship_stage,first_met_at,last_interaction_at
  )
  VALUES(l.user_id,l.character_id,0,'first_meeting',clock_timestamp(),clock_timestamp())
  ON CONFLICT (user_id,character_id) DO NOTHING;

  SELECT s.id,s.affinity INTO v_state_id,v_current
  FROM public.encounter_character_state AS s
  WHERE s.user_id = l.user_id AND s.character_id = l.character_id
  FOR UPDATE;

  v_final := greatest(-100,least(100,v_current+p_affinity_delta));
  UPDATE public.encounter_character_state
  SET affinity = v_final,
      relationship_stage = p_relationship_stage,
      last_interaction_at = clock_timestamp(),
      updated_at = clock_timestamp()
  WHERE id = v_state_id;

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
  SET status = 'settled',
      settlement_delta = v_final-v_current,
      settlement_result = v_result,
      settled_at = clock_timestamp(),
      updated_at = clock_timestamp()
  WHERE session_id = p_session_id;

  RETURN jsonb_build_object('settled',true,'idempotent',false,'result',v_result);
END;
$function$;

CREATE OR REPLACE FUNCTION public.validate_affinity_session_link()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid;
  v_character_id uuid;
  v_chat_mode text;
BEGIN
  -- Link mutations must serialize with chat deletion and must not attach new
  -- evidence/state to a deleted session.
  SELECT s.user_id, s.character_id, s.chat_mode
    INTO v_user_id, v_character_id, v_chat_mode
  FROM public.chat_sessions AS s
  WHERE s.id = NEW.session_id
    AND s.deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Affinity session is missing or deleted' USING ERRCODE='23503';
  END IF;
  IF v_user_id IS DISTINCT FROM NEW.user_id THEN
    RAISE EXCEPTION 'Affinity session owner mismatch' USING ERRCODE='23514';
  END IF;
  IF NEW.character_id IS NOT NULL
     AND v_character_id IS DISTINCT FROM NEW.character_id THEN
    RAISE EXCEPTION 'Affinity session character mismatch' USING ERRCODE='23514';
  END IF;

  IF TG_TABLE_NAME = 'encounter_session_lifecycle'
     AND v_chat_mode <> 'encounter' THEN
    RAISE EXCEPTION 'Encounter lifecycle requires an Encounter session' USING ERRCODE='23514';
  ELSIF TG_TABLE_NAME = 'story_relationship_states'
     AND v_chat_mode <> 'story' THEN
    RAISE EXCEPTION 'Story relationship requires a Story session' USING ERRCODE='23514';
  ELSIF TG_TABLE_NAME = 'story_relationship_batches'
     AND v_chat_mode <> 'story' THEN
    RAISE EXCEPTION 'Story batch requires a Story session' USING ERRCODE='23514';
  ELSIF TG_TABLE_NAME = 'encounter_session_turns'
     AND v_chat_mode <> 'encounter' THEN
    RAISE EXCEPTION 'Encounter turn requires an Encounter session' USING ERRCODE='23514';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.validate_encounter_evaluation_job_link()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid;
  v_character_id uuid;
  v_chat_mode text;
BEGIN
  SELECT s.user_id, s.character_id, s.chat_mode
    INTO v_user_id, v_character_id, v_chat_mode
  FROM public.chat_sessions AS s
  WHERE s.id = NEW.session_id
    AND s.deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND
     OR v_user_id IS DISTINCT FROM NEW.user_id
     OR v_chat_mode <> 'encounter'
     OR (NEW.character_id IS NOT NULL AND v_character_id IS DISTINCT FROM NEW.character_id) THEN
    RAISE EXCEPTION 'Encounter evaluation job session link is invalid or deleted' USING ERRCODE='23514';
  END IF;

  RETURN NEW;
END;
$function$;
