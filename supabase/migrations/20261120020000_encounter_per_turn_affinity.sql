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
  RETURN jsonb_build_object('affinity',v_after,'relationship_stage',v_stage,'idempotent',false);
END; $$;
REVOKE ALL ON FUNCTION public.apply_encounter_turn_affinity(uuid,uuid,uuid,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.apply_encounter_turn_affinity(uuid,uuid,uuid,integer) TO service_role;
