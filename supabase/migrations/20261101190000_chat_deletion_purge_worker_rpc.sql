-- PR #200: service-role-only 30-day content purge and durable worker queue APIs.
-- Keep minimal parent/message tombstones so billing FKs and audit references remain valid.
-- All user-visible chat text, versions, AI raw content and chat-memory metadata are purged.

CREATE OR REPLACE FUNCTION public.save_chat_message_version()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF auth.role() = 'service_role'
     AND current_setting('app.chat_purge_worker', true) = 'on' THEN
    RETURN NEW;
  END IF;

  IF OLD.content IS DISTINCT FROM NEW.content THEN
    INSERT INTO public.chat_message_versions(message_id, content, edited_by)
    VALUES (OLD.id, OLD.content, auth.uid());
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.guard_chat_turn_assistant_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_locked_charge public.chat_turn_charges%rowtype;
  v_old_charge public.chat_turn_charges%rowtype;
  v_new_charge public.chat_turn_charges%rowtype;
  v_has_old_charge boolean := false;
  v_has_new_charge boolean := false;
  v_content_changed boolean;
  v_deleted_changed boolean;
BEGIN
  IF auth.role() = 'service_role'
     AND current_setting('app.chat_purge_worker', true) = 'on' THEN
    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.session_id IS DISTINCT FROM OLD.session_id
       OR NEW.role IS DISTINCT FROM OLD.role THEN
      RAISE EXCEPTION 'chat_purge_worker_identity_change_forbidden';
    END IF;
    RETURN NEW;
  END IF;

  PERFORM 1 FROM public.chat_sessions s
  WHERE s.id=OLD.session_id AND s.deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'chat_session_not_found_or_deleted'; END IF;

  IF NEW.role IS DISTINCT FROM OLD.role THEN RAISE EXCEPTION 'chat_message_role_is_immutable'; END IF;
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.session_id IS DISTINCT FROM OLD.session_id THEN
    IF OLD.role='assistant' THEN RAISE EXCEPTION 'assistant_message_identity_is_immutable';
    ELSE RAISE EXCEPTION 'user_message_identity_is_immutable'; END IF;
  END IF;
  IF OLD.role<>'assistant' THEN RETURN NEW; END IF;

  v_content_changed:=NEW.content IS DISTINCT FROM OLD.content;
  v_deleted_changed:=NEW.deleted_at IS DISTINCT FROM OLD.deleted_at;
  FOR v_locked_charge IN
    SELECT c.* FROM public.chat_turn_charges c
    WHERE c.expected_assistant_message_id=OLD.id OR c.expected_assistant_message_id=NEW.id
    ORDER BY c.expected_assistant_message_id FOR UPDATE
  LOOP
    IF v_locked_charge.expected_assistant_message_id=OLD.id THEN v_old_charge:=v_locked_charge; v_has_old_charge:=true; END IF;
    IF v_locked_charge.expected_assistant_message_id=NEW.id THEN v_new_charge:=v_locked_charge; v_has_new_charge:=true; END IF;
  END LOOP;
  IF v_has_old_charge AND v_has_new_charge AND v_old_charge.turn_id IS DISTINCT FROM v_new_charge.turn_id THEN RAISE EXCEPTION 'assistant_message_turn_id_conflict'; END IF;
  IF v_has_old_charge AND OLD.id IS DISTINCT FROM v_old_charge.expected_assistant_message_id THEN RAISE EXCEPTION 'assistant_message_turn_id_conflict'; END IF;
  IF v_deleted_changed THEN
    IF v_content_changed THEN RAISE EXCEPTION 'assistant_reply_edit_and_delete_must_be_separate'; END IF;
    IF v_has_old_charge AND v_old_charge.status IS DISTINCT FROM 'settled' THEN RAISE EXCEPTION 'chat_turn_reply_delete_requires_settled_charge'; END IF;
    RETURN NEW;
  END IF;
  IF v_content_changed AND v_has_old_charge AND v_old_charge.status IS DISTINCT FROM 'settled' THEN RAISE EXCEPTION 'assistant_reply_edit_requires_settled_charge'; END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.claim_chat_deletion_jobs(p_limit integer DEFAULT 10)
RETURNS TABLE(job_id uuid,resource_type text,resource_id uuid,owner_id uuid,purge_after timestamptz,attempt_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE v_limit integer:=LEAST(GREATEST(COALESCE(p_limit,10),1),50);
BEGIN
  IF COALESCE(auth.role(),'')<>'service_role' THEN RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501'; END IF;
  RETURN QUERY
  WITH candidates AS (
    SELECT j.id FROM public.chat_deletion_jobs j
    WHERE j.purge_after<=clock_timestamp()
      AND j.attempt_count<8
      AND (
        (j.status IN ('queued','retry') AND (j.next_attempt_at IS NULL OR j.next_attempt_at<=clock_timestamp()))
        OR (j.status='processing' AND j.lease_until<=clock_timestamp())
      )
    ORDER BY j.purge_after,j.created_at
    FOR UPDATE SKIP LOCKED
    LIMIT v_limit
  )
  UPDATE public.chat_deletion_jobs j
  SET status='processing',attempt_count=j.attempt_count+1,
      next_attempt_at=NULL,lease_until=clock_timestamp()+interval '5 minutes',
      updated_at=clock_timestamp()
  FROM candidates c
  WHERE j.id=c.id
  RETURNING j.id,j.resource_type,j.resource_id,j.owner_id,j.purge_after,j.attempt_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.purge_chat_deletion_job(p_job_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_job public.chat_deletion_jobs%ROWTYPE;
  v_owner_id uuid;
  v_parent_deleted_at timestamptz;
  v_parent_found boolean:=false;
BEGIN
  IF COALESCE(auth.role(),'')<>'service_role' THEN RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501'; END IF;
  IF p_job_id IS NULL THEN RAISE EXCEPTION 'job_id_required' USING ERRCODE='22023'; END IF;

  SELECT * INTO v_job FROM public.chat_deletion_jobs WHERE id=p_job_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'chat_deletion_job_not_found'; END IF;
  IF v_job.status='completed' THEN RETURN true; END IF;
  IF v_job.purge_after>clock_timestamp() THEN RAISE EXCEPTION 'chat_deletion_not_due'; END IF;

  -- Lock the resource parent before the queue row; this matches every writer lock order.
  IF v_job.resource_type='single_session' THEN
    SELECT s.user_id,s.deleted_at INTO v_owner_id,v_parent_deleted_at
    FROM public.chat_sessions s WHERE s.id=v_job.resource_id FOR UPDATE;
    v_parent_found:=FOUND;
  ELSIF v_job.resource_type='group' THEN
    SELECT g.owner_id,g.deleted_at INTO v_owner_id,v_parent_deleted_at
    FROM public.chat_groups g WHERE g.id=v_job.resource_id FOR UPDATE;
    v_parent_found:=FOUND;
  ELSE
    RAISE EXCEPTION 'unsupported_chat_resource_type';
  END IF;

  SELECT * INTO v_job FROM public.chat_deletion_jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'chat_deletion_job_not_found'; END IF;
  IF v_job.status='completed' THEN RETURN true; END IF;
  IF v_job.status<>'processing' OR v_job.lease_until IS NULL OR v_job.lease_until<=clock_timestamp() THEN
    RAISE EXCEPTION 'chat_deletion_job_lease_not_owned';
  END IF;

  IF v_parent_found THEN
    IF v_owner_id IS DISTINCT FROM v_job.owner_id OR v_parent_deleted_at IS DISTINCT FROM v_job.deleted_at THEN
      RAISE EXCEPTION 'chat_deletion_parent_mismatch';
    END IF;

    PERFORM set_config('app.chat_purge_worker','on',true);

    IF v_job.resource_type='single_session' THEN
      DELETE FROM public.chat_message_versions v
      WHERE v.message_id IN (SELECT m.id FROM public.chat_messages m WHERE m.session_id=v_job.resource_id);

      UPDATE public.chat_messages m
      SET content='',deleted_at=COALESCE(m.deleted_at,v_job.deleted_at)
      WHERE m.session_id=v_job.resource_id;

      UPDATE public.ai_generation_records
      SET original_content=''
      WHERE session_id=v_job.resource_id AND user_id=v_job.owner_id;

      UPDATE public.encounter_session_turns
      SET evaluation='{}'::jsonb
      WHERE session_id=v_job.resource_id;

      UPDATE public.encounter_session_lifecycle
      SET schedule_snapshot='{}'::jsonb,settlement_result='{}'::jsonb,updated_at=clock_timestamp()
      WHERE session_id=v_job.resource_id;

      DELETE FROM public.encounter_session_evaluation_jobs
      WHERE session_id=v_job.resource_id;

      UPDATE public.encounter_turn_interaction_receipts r
      SET diary_id=NULL
      FROM public.chat_turn_charges c
      WHERE c.turn_id=r.turn_id AND c.session_id=v_job.resource_id AND r.diary_id IS NOT NULL;

      DELETE FROM public.encounter_diary d
      WHERE d.user_id=v_job.owner_id
        AND d.metadata->>'session_id'=v_job.resource_id::text;

      UPDATE public.story_relationship_batches
      SET summary=NULL,evaluation='{}'::jsonb
      WHERE session_id=v_job.resource_id;

      UPDATE public.story_relationship_states
      SET imported_memories='[]'::jsonb,updated_at=clock_timestamp()
      WHERE session_id=v_job.resource_id;

      DELETE FROM public.chat_memory_photos
      WHERE session_id=v_job.resource_id AND owner_id=v_job.owner_id;

      UPDATE public.chat_sessions
      SET session_data='{}'::jsonb,character_snapshot='{}'::jsonb,updated_at=clock_timestamp()
      WHERE id=v_job.resource_id AND user_id=v_job.owner_id;

    ELSE
      -- Clear the background FK before removing photo metadata.
      UPDATE public.chat_groups
      SET background_mode='none',background_memory_photo_id=NULL,
          name='已刪除對話',world_background='',player_name='',player_persona='',
          world_character_id=NULL,pinned=false,updated_at=clock_timestamp()
      WHERE id=v_job.resource_id AND owner_id=v_job.owner_id;

      DELETE FROM public.chat_group_messages WHERE group_id=v_job.resource_id;
      DELETE FROM public.chat_group_diary WHERE group_id=v_job.resource_id AND owner_id=v_job.owner_id;
      DELETE FROM public.chat_group_memory_photos WHERE group_id=v_job.resource_id AND owner_id=v_job.owner_id;
      DELETE FROM public.chat_memory_photos WHERE group_id=v_job.resource_id AND owner_id=v_job.owner_id;
      DELETE FROM public.chat_group_members WHERE group_id=v_job.resource_id;
      DELETE FROM public.chat_group_scenes WHERE group_id=v_job.resource_id;

      -- Keep group turn IDs and charge evidence, but remove the original user text.
      UPDATE public.chat_group_turns SET request_content='' WHERE group_id=v_job.resource_id;
    END IF;
  END IF;
  -- If the parent is already absent, account deletion has already removed relational
  -- children. The independent Storage queue remains available for object cleanup.

  UPDATE public.chat_deletion_jobs
  SET status='completed',next_attempt_at=NULL,lease_until=NULL,last_error_code=NULL,updated_at=clock_timestamp()
  WHERE id=p_job_id;
  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.mark_chat_deletion_job_failed(p_job_id uuid,p_error_code text DEFAULT 'purge_failed')
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE v_attempt integer; v_status text;
BEGIN
  IF COALESCE(auth.role(),'')<>'service_role' THEN RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501'; END IF;
  UPDATE public.chat_deletion_jobs j
  SET status=CASE WHEN j.attempt_count>=8 THEN 'dead_letter' ELSE 'retry' END,
      next_attempt_at=CASE WHEN j.attempt_count>=8 THEN NULL
        ELSE clock_timestamp()+make_interval(mins=>LEAST(60,power(2,LEAST(j.attempt_count,6))::integer)) END,
      lease_until=NULL,
      last_error_code=COALESCE(NULLIF(left(regexp_replace(COALESCE(p_error_code,'purge_failed'),'[^a-zA-Z0-9:_-]','','g'),100),''),'purge_failed'),
      updated_at=clock_timestamp()
  WHERE j.id=p_job_id AND j.status='processing';
  RETURN FOUND;
END;
$function$;

CREATE OR REPLACE FUNCTION public.claim_chat_storage_deletion_jobs(p_limit integer DEFAULT 25)
RETURNS TABLE(job_id uuid,deletion_job_id uuid,bucket_id text,object_path text,resource_type text,resource_id uuid,owner_id uuid,attempt_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE v_limit integer:=LEAST(GREATEST(COALESCE(p_limit,25),1),100);
BEGIN
  IF COALESCE(auth.role(),'')<>'service_role' THEN RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501'; END IF;
  RETURN QUERY
  WITH candidates AS (
    SELECT sj.id
    FROM public.chat_storage_deletion_jobs sj
    JOIN public.chat_deletion_jobs dj ON dj.id=sj.deletion_job_id
    WHERE dj.status='completed' AND dj.purge_after<=clock_timestamp()
      AND sj.attempt_count<8
      AND (
        (sj.status IN ('queued','retry') AND (sj.next_attempt_at IS NULL OR sj.next_attempt_at<=clock_timestamp()))
        OR (sj.status='processing' AND sj.lease_until<=clock_timestamp())
      )
    ORDER BY sj.created_at
    FOR UPDATE OF sj SKIP LOCKED
    LIMIT v_limit
  )
  UPDATE public.chat_storage_deletion_jobs sj
  SET status='processing',attempt_count=sj.attempt_count+1,
      next_attempt_at=NULL,lease_until=clock_timestamp()+interval '5 minutes',
      updated_at=clock_timestamp()
  FROM candidates c
  WHERE sj.id=c.id
  RETURNING sj.id,sj.deletion_job_id,sj.bucket_id,sj.object_path,sj.resource_type,sj.resource_id,sj.owner_id,sj.attempt_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.mark_chat_storage_deletion_job(p_job_id uuid,p_success boolean,p_error_code text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF COALESCE(auth.role(),'')<>'service_role' THEN RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501'; END IF;
  IF p_success IS TRUE THEN
    UPDATE public.chat_storage_deletion_jobs
    SET status='completed',next_attempt_at=NULL,lease_until=NULL,last_error_code=NULL,updated_at=clock_timestamp()
    WHERE id=p_job_id AND status='processing';
  ELSE
    UPDATE public.chat_storage_deletion_jobs sj
    SET status=CASE WHEN sj.attempt_count>=8 THEN 'dead_letter' ELSE 'retry' END,
        next_attempt_at=CASE WHEN sj.attempt_count>=8 THEN NULL
          ELSE clock_timestamp()+make_interval(mins=>LEAST(60,power(2,LEAST(sj.attempt_count,6))::integer)) END,
        lease_until=NULL,
        last_error_code=COALESCE(NULLIF(left(regexp_replace(COALESCE(p_error_code,'storage_delete_failed'),'[^a-zA-Z0-9:_-]','','g'),100),''),'storage_delete_failed'),
        updated_at=clock_timestamp()
    WHERE sj.id=p_job_id AND sj.status='processing';
  END IF;
  RETURN FOUND;
END;
$function$;

REVOKE ALL ON FUNCTION public.claim_chat_deletion_jobs(integer) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.purge_chat_deletion_job(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.mark_chat_deletion_job_failed(uuid,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.claim_chat_storage_deletion_jobs(integer) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.mark_chat_storage_deletion_job(uuid,boolean,text) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.claim_chat_deletion_jobs(integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.purge_chat_deletion_job(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.mark_chat_deletion_job_failed(uuid,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.claim_chat_storage_deletion_jobs(integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.mark_chat_storage_deletion_job(uuid,boolean,text) TO service_role;
