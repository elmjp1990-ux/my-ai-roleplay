-- Atomically update pause/resume flags without overwriting concurrent Encounter session_data writes.
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
  WHERE id=p_session_id AND user_id=p_user_id AND chat_mode='encounter' AND deleted_at IS NULL
  RETURNING session_data INTO v_session_data;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'encounter_session_metadata_not_found' USING ERRCODE='P0002';
  END IF;
  RETURN jsonb_build_object('persisted',true,'encounterTemporarilyLeftAt',v_left_at);
END;
$function$;

REVOKE ALL ON FUNCTION public.persist_encounter_session_pause_resume_metadata(uuid,uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.persist_encounter_session_pause_resume_metadata(uuid,uuid,text) TO service_role;
