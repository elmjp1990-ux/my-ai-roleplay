-- Seed new Encounter sessions from the user's canonical relationship instead of resetting to first meeting.
CREATE OR REPLACE FUNCTION public.create_encounter_session_with_lifecycle(
  p_session_id uuid,
  p_user_id uuid,
  p_character_id uuid,
  p_character_name text,
  p_character_snapshot jsonb,
  p_schedule_snapshot jsonb,
  p_location_key text,
  p_scheduled_start_at timestamptz,
  p_scheduled_end_at timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_session jsonb;
  v_affinity integer := 0;
  v_relationship_stage text := 'first_meeting';
BEGIN
  IF p_session_id IS NULL OR p_user_id IS NULL OR p_character_id IS NULL
     OR p_location_key IS NULL OR char_length(p_location_key) NOT BETWEEN 1 AND 80
     OR jsonb_typeof(COALESCE(p_character_snapshot, '{}'::jsonb)) <> 'object'
     OR jsonb_typeof(COALESCE(p_schedule_snapshot, '{}'::jsonb)) <> 'object'
     OR pg_column_size(COALESCE(p_schedule_snapshot, '{}'::jsonb)) > 8000
     OR p_scheduled_start_at IS NULL OR p_scheduled_end_at IS NULL
     OR p_scheduled_end_at <= p_scheduled_start_at THEN
    RAISE EXCEPTION 'Invalid Encounter session lifecycle input' USING ERRCODE = '22023';
  END IF;

  -- Prefer the canonical Encounter relationship (updated by each settled turn).
  SELECT state.affinity,state.relationship_stage
  INTO v_affinity,v_relationship_stage
  FROM public.encounter_character_state AS state
  WHERE state.user_id=p_user_id AND state.character_id=p_character_id;

  IF NOT FOUND THEN
    -- If the player has a Story relationship but no Encounter state yet, carry
    -- the latest Story relationship into Encounter rather than showing "unknown".
    SELECT story.affinity,story.relationship_stage
    INTO v_affinity,v_relationship_stage
    FROM public.story_relationship_states AS story
    JOIN public.chat_sessions AS source_session ON source_session.id=story.session_id
    WHERE story.user_id=p_user_id AND story.character_id=p_character_id
      AND source_session.user_id=p_user_id AND source_session.chat_mode='story'
      AND source_session.deleted_at IS NULL
    ORDER BY story.updated_at DESC,story.session_id DESC
    LIMIT 1;
    IF NOT FOUND THEN
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
    WHERE state.user_id=p_user_id AND state.character_id=p_character_id;
  END IF;

  INSERT INTO public.chat_sessions (
    id,user_id,character_id,character_name,status,character_snapshot,session_data,chat_mode
  ) VALUES (
    p_session_id,p_user_id,p_character_id,p_character_name,'active',
    COALESCE(p_character_snapshot,'{}'::jsonb),
    jsonb_build_object('encounter',jsonb_build_object('affinity',v_affinity,'relationshipStage',v_relationship_stage)),
    'encounter'
  );

  INSERT INTO public.encounter_session_lifecycle (
    session_id,user_id,character_id,location_key,schedule_snapshot,
    scheduled_start_at,scheduled_end_at,timezone,status
  ) VALUES (
    p_session_id,p_user_id,p_character_id,p_location_key,p_schedule_snapshot,
    p_scheduled_start_at,p_scheduled_end_at,'Asia/Taipei','active'
  );

  SELECT jsonb_build_object(
    'id',s.id,'user_id',s.user_id,'character_id',s.character_id,
    'character_name',s.character_name,'status',s.status,
    'character_snapshot',s.character_snapshot,'session_data',s.session_data,
    'chat_mode',s.chat_mode,'created_at',s.created_at,'updated_at',s.updated_at
  ) INTO v_session
  FROM public.chat_sessions AS s WHERE s.id=p_session_id;
  RETURN v_session;
END;
$$;

REVOKE ALL ON FUNCTION public.create_encounter_session_with_lifecycle(
  uuid,uuid,uuid,text,jsonb,jsonb,text,timestamptz,timestamptz
) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.create_encounter_session_with_lifecycle(
  uuid,uuid,uuid,text,jsonb,jsonb,text,timestamptz,timestamptz
) TO service_role;
