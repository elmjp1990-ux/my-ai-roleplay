BEGIN;

-- TEST had the Edge Function deployed before this RPC existed in its schema.
-- Keep this definition idempotent so a missing historical migration can be repaired safely.
CREATE OR REPLACE FUNCTION public.persist_encounter_session_pause_resume_metadata(
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
  v_left_at bigint;
BEGIN
  IF NOT public.is_service_role_request() THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
  END IF;
  IF p_session_id IS NULL OR p_user_id IS NULL OR p_action IS NULL OR p_action NOT IN ('pause','resume') THEN
    RAISE EXCEPTION 'invalid_encounter_pause_resume_metadata' USING ERRCODE='22023';
  END IF;

  v_left_at := CASE WHEN p_action='pause'
    THEN (extract(epoch FROM pg_catalog.clock_timestamp())*1000)::bigint
    ELSE NULL END;

  UPDATE public.chat_sessions
  SET session_data=COALESCE(session_data,'{}'::jsonb)||
        jsonb_build_object('archived',false,'archivedAt',NULL,'encounterTemporarilyLeftAt',v_left_at),
      updated_at=pg_catalog.clock_timestamp()
  WHERE id=p_session_id AND user_id=p_user_id AND chat_mode='encounter' AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'encounter_session_metadata_not_found' USING ERRCODE='P0002';
  END IF;
  RETURN jsonb_build_object('persisted',true,'encounterTemporarilyLeftAt',v_left_at);
END;
$function$;

REVOKE ALL ON FUNCTION public.persist_encounter_session_pause_resume_metadata(uuid,uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.persist_encounter_session_pause_resume_metadata(uuid,uuid,text) TO service_role;

-- New Encounter sessions without an existing Story/Encounter relationship remain strangers.
-- Support both the current main definition (which can import a Story relationship)
-- and the older TEST definition (which only reads an existing Encounter state).
DO $seed$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.create_encounter_session_with_lifecycle(uuid,uuid,uuid,text,jsonb,jsonb,text,timestamptz,timestamptz)'::regprocedure
  ) INTO v_definition;

  v_old := $old$    IF NOT FOUND THEN
      v_affinity:=0;
      v_relationship_stage:='first_meeting';
    END IF;
    INSERT INTO public.encounter_character_state(
      user_id,character_id,affinity,relationship_stage,first_met_at,last_interaction_at
    ) VALUES(p_user_id,p_character_id,v_affinity,v_relationship_stage,clock_timestamp(),clock_timestamp())
    ON CONFLICT(user_id,character_id) DO NOTHING;
    -- A concurrent creation may have initialized the row first; read its value.
    SELECT state.affinity,state.relationship_stage
    INTO v_affinity,v_relationship_stage
    FROM public.encounter_character_state AS state
    WHERE state.user_id=p_user_id AND state.character_id=p_character_id;$old$;
  v_new := $new$    IF NOT FOUND THEN
      v_affinity:=0;
      v_relationship_stage:='stranger';
    ELSE
      INSERT INTO public.encounter_character_state(
        user_id,character_id,affinity,relationship_stage,first_met_at,last_interaction_at
      ) VALUES(p_user_id,p_character_id,v_affinity,v_relationship_stage,clock_timestamp(),clock_timestamp())
      ON CONFLICT(user_id,character_id) DO NOTHING;
      -- A concurrent creation may have initialized the row first; read its value.
      SELECT state.affinity,state.relationship_stage
      INTO v_affinity,v_relationship_stage
      FROM public.encounter_character_state AS state
      WHERE state.user_id=p_user_id AND state.character_id=p_character_id;
    END IF;$new$;

  IF pg_catalog.strpos(v_definition,v_old)>0 THEN
    v_definition := pg_catalog.replace(v_definition,v_old,v_new);
    EXECUTE v_definition;
  ELSE
    v_old := $old$  SELECT state.affinity INTO v_affinity FROM public.encounter_character_state state WHERE state.user_id=p_user_id AND state.character_id=p_character_id;
  v_affinity := COALESCE(v_affinity,0);
  v_stage := public.story_relationship_stage_for_affinity(v_affinity);$old$;
    v_new := $new$  SELECT state.affinity INTO v_affinity FROM public.encounter_character_state state WHERE state.user_id=p_user_id AND state.character_id=p_character_id;
  IF NOT FOUND THEN
    v_affinity := 0;
    v_stage := 'stranger';
  ELSE
    v_stage := public.story_relationship_stage_for_affinity(v_affinity);
  END IF;$new$;

    IF pg_catalog.strpos(v_definition,v_old)=0 THEN
      RAISE EXCEPTION 'encounter_session_relationship_seed_anchor_missing';
    END IF;
    v_definition := pg_catalog.replace(v_definition,v_old,v_new);
    EXECUTE v_definition;
  END IF;
END;
$seed$;

-- A scene with no turn evidence is not a first meeting. Cancel it instead of
-- creating encounter_character_state or making it eligible for diary carry-over.
DO $migration$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.set_encounter_session_lifecycle_state(uuid,uuid,text)'::regprocedure
  ) INTO v_definition;

  v_old := $old$    IF l.status='cancelled' THEN
      RAISE EXCEPTION 'Encounter scene is closed' USING ERRCODE='23514';
    END IF;
    IF l.status='ready_to_settle' THEN$old$;
  v_new := $new$    IF l.status='cancelled' THEN
      RETURN jsonb_build_object('session_id',p_session_id,'status','cancelled','idempotent',true,'no_interaction',true);
    END IF;

    IF l.turn_count=0
       AND NOT EXISTS (
         SELECT 1 FROM public.encounter_session_turns AS turn
         WHERE turn.session_id=p_session_id
       )
       AND NOT EXISTS (
         SELECT 1 FROM public.chat_turn_charges AS charge
         WHERE charge.session_id=p_session_id
           AND charge.status IN ('created','reserved','needs_reconciliation','settled')
       ) THEN
      UPDATE public.encounter_session_lifecycle
      SET status='cancelled',settlement_delta=0,settlement_result=NULL,
          settled_at=NULL,updated_at=pg_catalog.clock_timestamp()
      WHERE session_id=p_session_id;
      RETURN jsonb_build_object('session_id',p_session_id,'status','cancelled','idempotent',false,'no_interaction',true);
    END IF;

    IF l.status='ready_to_settle' THEN$new$;

  IF pg_catalog.strpos(v_definition,v_old)=0 THEN
    RAISE EXCEPTION 'empty_encounter_lifecycle_anchor_missing';
  END IF;
  v_definition := pg_catalog.replace(v_definition,v_old,v_new);
  EXECUTE v_definition;

  SELECT pg_catalog.pg_get_functiondef(
    'public.settle_encounter_session(uuid,integer,text,jsonb,jsonb)'::regprocedure
  ) INTO v_definition;

  v_old := '  INSERT INTO public.encounter_character_state(';
  v_new := $new$  IF l.turn_count=0 THEN
    IF EXISTS (
      SELECT 1 FROM public.chat_turn_charges AS charge
      WHERE charge.session_id=p_session_id
        AND charge.status IN ('created','reserved','needs_reconciliation')
    ) THEN
      RAISE EXCEPTION 'Encounter has pending turns without evidence' USING ERRCODE='23514';
    END IF;

    UPDATE public.encounter_session_lifecycle
    SET status='cancelled',settlement_delta=0,settlement_result=NULL,
        settled_at=NULL,updated_at=pg_catalog.clock_timestamp()
    WHERE session_id=p_session_id;

    RETURN jsonb_build_object(
      'settled',true,'no_interaction',true,'idempotent',false,'result',NULL
    );
  END IF;

  INSERT INTO public.encounter_character_state($new$;

  IF pg_catalog.strpos(v_definition,v_old)=0 THEN
    RAISE EXCEPTION 'empty_encounter_settlement_anchor_missing';
  END IF;
  v_definition := pg_catalog.replace(v_definition,v_old,v_new);
  EXECUTE v_definition;
END;
$migration$;

COMMIT;
