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
     OR p_action IS NULL OR p_action NOT IN ('pause','resume') THEN
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

-- Settlement definition intentionally extracted to the focused, canonical draft:
-- supabase/drafts/settle-encounter-session-parent-lock-live-reconciliation.sql
-- Apply/review that file as the sole settle_encounter_session replacement.
-- Do not add a second settlement definition here: keeping one canonical body
-- prevents later CREATE OR REPLACE statements from silently overwriting the
-- parent-first deleted-session gate or its explicit EXECUTE ACL.

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
