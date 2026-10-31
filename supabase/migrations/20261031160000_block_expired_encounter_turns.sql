-- Atomic Encounter turn evidence writer. No affinity mutation.
CREATE OR REPLACE FUNCTION public.record_encounter_session_turn_evidence(p_turn_id uuid,p_session_id uuid,p_user_id uuid,p_character_id uuid,p_user_message_id uuid,p_assistant_message_id uuid,p_evaluation jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE l public.encounter_session_lifecycle%ROWTYPE; c public.chat_turn_charges%ROWTYPE; um public.chat_messages%ROWTYPE; am public.chat_messages%ROWTYPE; oldrow public.encounter_session_turns%ROWTYPE; n integer;
BEGIN
 IF p_turn_id IS NULL OR p_session_id IS NULL OR p_user_id IS NULL OR p_character_id IS NULL OR p_user_message_id IS NULL OR p_assistant_message_id IS NULL OR jsonb_typeof(COALESCE(p_evaluation,'{}'::jsonb)) <> 'object' OR pg_column_size(COALESCE(p_evaluation,'{}'::jsonb)) > 8000 THEN RAISE EXCEPTION 'Invalid evidence input' USING ERRCODE='22023'; END IF;
 SELECT * INTO l FROM public.encounter_session_lifecycle WHERE session_id=p_session_id FOR UPDATE;
 IF NOT FOUND OR l.user_id IS DISTINCT FROM p_user_id OR l.character_id IS DISTINCT FROM p_character_id OR l.status NOT IN ('active','paused') OR l.scheduled_end_at <= now() THEN RAISE EXCEPTION 'Invalid or expired Encounter lifecycle' USING ERRCODE='23514'; END IF;
 SELECT * INTO c FROM public.chat_turn_charges WHERE turn_id=p_turn_id FOR SHARE;
 IF NOT FOUND OR c.session_id IS DISTINCT FROM p_session_id OR c.user_id IS DISTINCT FROM p_user_id OR c.status <> 'settled' OR c.user_message_id IS DISTINCT FROM p_user_message_id OR c.assistant_message_id IS DISTINCT FROM p_assistant_message_id OR c.expected_assistant_message_id IS DISTINCT FROM p_assistant_message_id THEN RAISE EXCEPTION 'Charge evidence mismatch or unsettled' USING ERRCODE='23514'; END IF;
 SELECT * INTO um FROM public.chat_messages WHERE id=p_user_message_id FOR SHARE;
 IF NOT FOUND OR um.session_id IS DISTINCT FROM p_session_id OR um.role <> 'user' OR um.deleted_at IS NOT NULL OR length(btrim(um.content))=0 THEN RAISE EXCEPTION 'Invalid user message evidence' USING ERRCODE='23514'; END IF;
 SELECT * INTO am FROM public.chat_messages WHERE id=p_assistant_message_id FOR SHARE;
 IF NOT FOUND OR am.session_id IS DISTINCT FROM p_session_id OR am.role <> 'assistant' OR am.deleted_at IS NOT NULL OR length(btrim(am.content))=0 THEN RAISE EXCEPTION 'Invalid assistant message evidence' USING ERRCODE='23514'; END IF;
 SELECT * INTO oldrow FROM public.encounter_session_turns WHERE turn_id=p_turn_id;
 IF FOUND THEN
  IF oldrow.session_id IS DISTINCT FROM p_session_id OR oldrow.user_id IS DISTINCT FROM p_user_id OR oldrow.character_id IS DISTINCT FROM p_character_id OR oldrow.user_message_id IS DISTINCT FROM p_user_message_id OR oldrow.assistant_message_id IS DISTINCT FROM p_assistant_message_id THEN RAISE EXCEPTION 'Evidence idempotency collision' USING ERRCODE='23505'; END IF;
  RETURN jsonb_build_object('turn_id',oldrow.turn_id,'turn_number',oldrow.turn_number,'status',oldrow.evaluation_status,'idempotent',true);
 END IF;
 n := l.turn_count+1;
 INSERT INTO public.encounter_session_turns(turn_id,session_id,user_id,character_id,user_message_id,assistant_message_id,turn_number,evaluation_status,evaluation) VALUES(p_turn_id,p_session_id,p_user_id,p_character_id,p_user_message_id,p_assistant_message_id,n,'pending',COALESCE(p_evaluation,'{}'::jsonb));
 UPDATE public.encounter_session_lifecycle SET turn_count=n,updated_at=now() WHERE session_id=p_session_id;
 RETURN jsonb_build_object('turn_id',p_turn_id,'turn_number',n,'status','pending','idempotent',false);
END; $$;
REVOKE ALL ON FUNCTION public.record_encounter_session_turn_evidence(uuid,uuid,uuid,uuid,uuid,uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.record_encounter_session_turn_evidence(uuid,uuid,uuid,uuid,uuid,uuid,jsonb) TO service_role;
