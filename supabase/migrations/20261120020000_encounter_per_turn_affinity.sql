-- Encounter per-turn affinity updates: bounded, charge-settled, idempotent.
CREATE TABLE IF NOT EXISTS public.encounter_turn_affinity_receipts (
  turn_id uuid PRIMARY KEY REFERENCES public.chat_turn_charges(turn_id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  character_id uuid NOT NULL REFERENCES public.characters(id) ON DELETE CASCADE,
  affinity_delta smallint NOT NULL CHECK (affinity_delta BETWEEN -3 AND 3),
  affinity_after integer NOT NULL CHECK (affinity_after BETWEEN -100 AND 100),
  relationship_stage text NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.encounter_turn_affinity_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.encounter_turn_affinity_receipts FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_turn_affinity_receipts TO service_role;

CREATE OR REPLACE FUNCTION public.apply_encounter_turn_affinity(
  p_turn_id uuid, p_user_id uuid, p_character_id uuid, p_affinity_delta integer
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_session_id uuid;
  v_current integer;
  v_after integer;
  v_stage text;
  v_receipt public.encounter_turn_affinity_receipts%ROWTYPE;
  v_inserted integer;
BEGIN
  IF NOT public.is_service_role_request() THEN RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501'; END IF;
  IF p_turn_id IS NULL OR p_user_id IS NULL OR p_character_id IS NULL OR p_affinity_delta IS NULL OR p_affinity_delta NOT BETWEEN -3 AND 3 THEN
    RAISE EXCEPTION 'invalid_encounter_affinity_input' USING ERRCODE='22023';
  END IF;
  SELECT c.session_id INTO v_session_id FROM public.chat_turn_charges c
  WHERE c.turn_id=p_turn_id AND c.user_id=p_user_id AND c.status='settled';
  IF NOT FOUND THEN RAISE EXCEPTION 'encounter_affinity_requires_settled_turn' USING ERRCODE='23514'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.chat_sessions s WHERE s.id=v_session_id AND s.user_id=p_user_id AND s.character_id=p_character_id AND s.chat_mode='encounter' AND s.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'encounter_affinity_session_invalid' USING ERRCODE='23514';
  END IF;
  INSERT INTO public.encounter_turn_affinity_receipts(turn_id,user_id,character_id,affinity_delta,affinity_after,relationship_stage)
  VALUES(p_turn_id,p_user_id,p_character_id,p_affinity_delta,0,'first_meeting') ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  IF v_inserted=0 THEN
    SELECT * INTO v_receipt FROM public.encounter_turn_affinity_receipts WHERE turn_id=p_turn_id;
    IF v_receipt.user_id<>p_user_id OR v_receipt.character_id<>p_character_id OR v_receipt.affinity_delta<>p_affinity_delta THEN RAISE EXCEPTION 'encounter_affinity_receipt_conflict' USING ERRCODE='23505'; END IF;
    RETURN jsonb_build_object('affinity',v_receipt.affinity_after,'relationship_stage',v_receipt.relationship_stage,'idempotent',true);
  END IF;
  INSERT INTO public.encounter_character_state(user_id,character_id,affinity,relationship_stage,first_met_at,last_interaction_at,updated_at)
  VALUES(p_user_id,p_character_id,0,'first_meeting',now(),now(),now()) ON CONFLICT(user_id,character_id) DO NOTHING;
  SELECT affinity INTO v_current FROM public.encounter_character_state WHERE user_id=p_user_id AND character_id=p_character_id FOR UPDATE;
  v_after := greatest(-100,least(100,v_current+p_affinity_delta));
  v_stage := public.story_relationship_stage_for_affinity(v_after);
  UPDATE public.encounter_character_state SET affinity=v_after,relationship_stage=v_stage,last_interaction_at=now(),updated_at=now()
    WHERE user_id=p_user_id AND character_id=p_character_id;
  UPDATE public.encounter_turn_affinity_receipts SET affinity_after=v_after,relationship_stage=v_stage WHERE turn_id=p_turn_id;
  UPDATE public.chat_sessions SET session_data=jsonb_set(COALESCE(session_data,'{}'::jsonb),'{encounter}',COALESCE(session_data->'encounter','{}'::jsonb)||jsonb_build_object('affinity',v_after,'relationshipStage',v_stage),true),updated_at=now()
    WHERE id=v_session_id AND user_id=p_user_id AND chat_mode='encounter';
  RETURN jsonb_build_object('affinity',v_after,'relationship_stage',v_stage,'idempotent',false);
END; $$;
REVOKE ALL ON FUNCTION public.apply_encounter_turn_affinity(uuid,uuid,uuid,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.apply_encounter_turn_affinity(uuid,uuid,uuid,integer) TO service_role;

ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS affinity_delta smallint CHECK (affinity_delta IS NULL OR affinity_delta BETWEEN -3 AND 3);
-- Keep shared affinity synchronized across Encounter and Story sessions.
CREATE OR REPLACE FUNCTION public.sync_shared_affinity_from_story()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_mode text; v_stage text;
BEGIN
  IF pg_trigger_depth()>1 THEN RETURN NEW; END IF;
  SELECT COALESCE(s.session_data->>'affinityMode','shared') INTO v_mode FROM public.chat_sessions s WHERE s.id=NEW.session_id;
  IF v_mode<>'shared' OR NEW.character_id IS NULL THEN RETURN NEW; END IF;
  v_stage := public.story_relationship_stage_for_affinity(NEW.affinity);
  INSERT INTO public.encounter_character_state(user_id,character_id,affinity,relationship_stage,first_met_at,last_interaction_at,updated_at)
  VALUES(NEW.user_id,NEW.character_id,NEW.affinity,v_stage,now(),now(),now())
  ON CONFLICT(user_id,character_id) DO UPDATE SET affinity=EXCLUDED.affinity,relationship_stage=EXCLUDED.relationship_stage,last_interaction_at=now(),updated_at=now();
  RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION public.sync_shared_affinity_to_story()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF pg_trigger_depth()>1 THEN RETURN NEW; END IF;
  UPDATE public.story_relationship_states r SET affinity=NEW.affinity,relationship_stage=NEW.relationship_stage,updated_at=now()
  FROM public.chat_sessions s WHERE s.id=r.session_id AND s.user_id=NEW.user_id AND s.character_id=NEW.character_id
    AND s.chat_mode='story' AND s.deleted_at IS NULL AND COALESCE(s.session_data->>'affinityMode','shared')='shared';
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS story_relationship_sync_shared_affinity ON public.story_relationship_states;
CREATE TRIGGER story_relationship_sync_shared_affinity AFTER UPDATE OF affinity,relationship_stage ON public.story_relationship_states
FOR EACH ROW WHEN (OLD.affinity IS DISTINCT FROM NEW.affinity OR OLD.relationship_stage IS DISTINCT FROM NEW.relationship_stage)
EXECUTE FUNCTION public.sync_shared_affinity_from_story();
DROP TRIGGER IF EXISTS encounter_state_sync_shared_affinity ON public.encounter_character_state;
CREATE TRIGGER encounter_state_sync_shared_affinity AFTER UPDATE OF affinity,relationship_stage ON public.encounter_character_state
FOR EACH ROW WHEN (OLD.affinity IS DISTINCT FROM NEW.affinity OR OLD.relationship_stage IS DISTINCT FROM NEW.relationship_stage)
EXECUTE FUNCTION public.sync_shared_affinity_to_story();
REVOKE ALL ON FUNCTION public.sync_shared_affinity_from_story() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.sync_shared_affinity_to_story() FROM PUBLIC,anon,authenticated;

-- New Encounter sessions inherit the user's canonical relationship with this character.
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
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_session jsonb;
  v_affinity integer := 0;
  v_stage text := 'first_meeting';
BEGIN
  IF NOT public.is_service_role_request() THEN RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501'; END IF;
  IF p_session_id IS NULL OR p_user_id IS NULL OR p_character_id IS NULL
     OR p_location_key IS NULL OR char_length(p_location_key) NOT BETWEEN 1 AND 80
     OR jsonb_typeof(COALESCE(p_character_snapshot, '{}'::jsonb)) <> 'object'
     OR jsonb_typeof(COALESCE(p_schedule_snapshot, '{}'::jsonb)) <> 'object'
     OR pg_column_size(COALESCE(p_schedule_snapshot, '{}'::jsonb)) > 8000
     OR p_scheduled_start_at IS NULL OR p_scheduled_end_at IS NULL
     OR p_scheduled_end_at <= p_scheduled_start_at THEN
    RAISE EXCEPTION 'Invalid Encounter session lifecycle input' USING ERRCODE = '22023';
  END IF;

  SELECT state.affinity INTO v_affinity
  FROM public.encounter_character_state state
  WHERE state.user_id=p_user_id AND state.character_id=p_character_id;

  v_affinity := COALESCE(v_affinity,0);
  v_stage := public.story_relationship_stage_for_affinity(v_affinity);

  INSERT INTO public.chat_sessions (
    id,user_id,character_id,character_name,status,character_snapshot,session_data,chat_mode
  ) VALUES (
    p_session_id,p_user_id,p_character_id,p_character_name,'active',
    COALESCE(p_character_snapshot,'{}'::jsonb),
    jsonb_build_object('encounter',jsonb_build_object('affinity',v_affinity,'relationshipStage',v_stage)),
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
  ) INTO v_session FROM public.chat_sessions s WHERE s.id=p_session_id;
  RETURN v_session;
END; $$;
REVOKE ALL ON FUNCTION public.create_encounter_session_with_lifecycle(uuid,uuid,uuid,text,jsonb,jsonb,text,timestamptz,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.create_encounter_session_with_lifecycle(uuid,uuid,uuid,text,jsonb,jsonb,text,timestamptz,timestamptz) TO service_role;

