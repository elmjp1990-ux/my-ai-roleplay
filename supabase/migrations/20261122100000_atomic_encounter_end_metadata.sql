-- Persist Encounter end metadata in-place without reading and resending the full session_data JSON.
CREATE OR REPLACE FUNCTION public.persist_encounter_session_end_metadata(
  p_session_id uuid,
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_ended_at bigint := (extract(epoch FROM pg_catalog.clock_timestamp()) * 1000)::bigint;
BEGIN
  IF NOT public.is_service_role_request() THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE='42501';
  END IF;
  IF p_session_id IS NULL OR p_user_id IS NULL THEN
    RAISE EXCEPTION 'invalid_encounter_end_metadata' USING ERRCODE='22023';
  END IF;

  UPDATE public.chat_sessions
  SET session_data = COALESCE(session_data, '{}'::jsonb) ||
        jsonb_build_object('archived', true, 'encounterEndedAt', v_ended_at),
      updated_at = pg_catalog.clock_timestamp()
  WHERE id = p_session_id
    AND user_id = p_user_id
    AND chat_mode = 'encounter'
    AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'encounter_session_metadata_not_found' USING ERRCODE='P0002';
  END IF;

  RETURN jsonb_build_object('persisted', true, 'encounterEndedAt', v_ended_at);
END;
$function$;

REVOKE ALL ON FUNCTION public.persist_encounter_session_end_metadata(uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.persist_encounter_session_end_metadata(uuid,uuid) TO service_role;
