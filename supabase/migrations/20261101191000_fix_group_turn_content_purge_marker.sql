-- Group turn request_content has a non-empty check; use a neutral tombstone marker.
CREATE OR REPLACE FUNCTION public.purge_chat_deletion_job(p_job_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_job public.chat_deletion_jobs%ROWTYPE; v_owner_id uuid; v_parent_deleted_at timestamptz; v_parent_found boolean:=false;
BEGIN
  IF COALESCE(auth.role(),'')<>'service_role' THEN RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501'; END IF;
  IF p_job_id IS NULL THEN RAISE EXCEPTION 'job_id_required' USING ERRCODE='22023'; END IF;
  SELECT * INTO v_job FROM public.chat_deletion_jobs WHERE id=p_job_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'chat_deletion_job_not_found'; END IF;
  IF v_job.status='completed' THEN RETURN true; END IF;
  IF v_job.purge_after>clock_timestamp() THEN RAISE EXCEPTION 'chat_deletion_not_due'; END IF;

  IF v_job.resource_type='single_session' THEN
    SELECT s.user_id,s.deleted_at INTO v_owner_id,v_parent_deleted_at FROM public.chat_sessions s WHERE s.id=v_job.resource_id FOR UPDATE;
    v_parent_found:=FOUND;
  ELSIF v_job.resource_type='group' THEN
    SELECT g.owner_id,g.deleted_at INTO v_owner_id,v_parent_deleted_at FROM public.chat_groups g WHERE g.id=v_job.resource_id FOR UPDATE;
    v_parent_found:=FOUND;
  ELSE RAISE EXCEPTION 'unsupported_chat_resource_type';
  END IF;

  SELECT * INTO v_job FROM public.chat_deletion_jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'chat_deletion_job_not_found'; END IF;
  IF v_job.status='completed' THEN RETURN true; END IF;
  IF v_job.status<>'processing' OR v_job.lease_until IS NULL OR v_job.lease_until<=clock_timestamp() THEN RAISE EXCEPTION 'chat_deletion_job_lease_not_owned'; END IF;

  IF v_parent_found THEN
    IF v_owner_id IS DISTINCT FROM v_job.owner_id OR v_parent_deleted_at IS DISTINCT FROM v_job.deleted_at THEN RAISE EXCEPTION 'chat_deletion_parent_mismatch'; END IF;
    PERFORM set_config('app.chat_purge_worker','on',true);

    IF v_job.resource_type='single_session' THEN
      DELETE FROM public.chat_message_versions v WHERE v.message_id IN (SELECT m.id FROM public.chat_messages m WHERE m.session_id=v_job.resource_id);
      UPDATE public.chat_messages m SET content='',deleted_at=COALESCE(m.deleted_at,v_job.deleted_at) WHERE m.session_id=v_job.resource_id;
      UPDATE public.ai_generation_records SET original_content='' WHERE session_id=v_job.resource_id AND user_id=v_job.owner_id;
      UPDATE public.encounter_session_turns SET evaluation='{}'::jsonb WHERE session_id=v_job.resource_id;
      UPDATE public.encounter_session_lifecycle SET schedule_snapshot='{}'::jsonb,settlement_result='{}'::jsonb,updated_at=clock_timestamp() WHERE session_id=v_job.resource_id;
      DELETE FROM public.encounter_session_evaluation_jobs WHERE session_id=v_job.resource_id;
      UPDATE public.encounter_turn_interaction_receipts r SET diary_id=NULL
      FROM public.chat_turn_charges c WHERE c.turn_id=r.turn_id AND c.session_id=v_job.resource_id AND r.diary_id IS NOT NULL;
      DELETE FROM public.encounter_diary d WHERE d.user_id=v_job.owner_id AND d.metadata->>'session_id'=v_job.resource_id::text;
      UPDATE public.story_relationship_batches SET summary=NULL,evaluation='{}'::jsonb WHERE session_id=v_job.resource_id;
      UPDATE public.story_relationship_states SET imported_memories='[]'::jsonb,updated_at=clock_timestamp() WHERE session_id=v_job.resource_id;
      DELETE FROM public.chat_memory_photos WHERE session_id=v_job.resource_id AND owner_id=v_job.owner_id;
      UPDATE public.chat_sessions SET session_data='{}'::jsonb,character_snapshot='{}'::jsonb,updated_at=clock_timestamp()
      WHERE id=v_job.resource_id AND user_id=v_job.owner_id;
    ELSE
      UPDATE public.chat_groups SET background_mode='none',background_memory_photo_id=NULL,
        name='已刪除對話',world_background='',player_name='',player_persona='',
        world_character_id=NULL,pinned=false,updated_at=clock_timestamp()
      WHERE id=v_job.resource_id AND owner_id=v_job.owner_id;
      DELETE FROM public.chat_group_messages WHERE group_id=v_job.resource_id;
      DELETE FROM public.chat_group_diary WHERE group_id=v_job.resource_id AND owner_id=v_job.owner_id;
      DELETE FROM public.chat_group_memory_photos WHERE group_id=v_job.resource_id AND owner_id=v_job.owner_id;
      DELETE FROM public.chat_memory_photos WHERE group_id=v_job.resource_id AND owner_id=v_job.owner_id;
      DELETE FROM public.chat_group_members WHERE group_id=v_job.resource_id;
      DELETE FROM public.chat_group_scenes WHERE group_id=v_job.resource_id;
      UPDATE public.chat_group_turns SET request_content='[purged]' WHERE group_id=v_job.resource_id;
    END IF;
  END IF;

  UPDATE public.chat_deletion_jobs SET status='completed',next_attempt_at=NULL,lease_until=NULL,last_error_code=NULL,updated_at=clock_timestamp()
  WHERE id=p_job_id;
  RETURN true;
END;
$function$;
