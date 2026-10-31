-- Server-authoritative pause/resume for Encounter sessions.
-- Leaving pauses new turns but preserves the session until its scheduled scene end.
CREATE OR REPLACE FUNCTION public.set_encounter_session_lifecycle_state(
  p_session_id uuid,
  p_user_id uuid,
  p_action text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  l public.encounter_session_lifecycle%ROWTYPE;
  v_status text;
BEGIN
  IF p_session_id IS NULL OR p_user_id IS NULL
     OR p_action NOT IN ('pause','resume') THEN
    RAISE EXCEPTION 'Invalid Encounter lifecycle state request' USING ERRCODE='22023';
  END IF;

  SELECT * INTO l
  FROM public.encounter_session_lifecycle
  WHERE session_id=p_session_id
  FOR UPDATE;

  IF NOT FOUND OR l.user_id IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'Encounter session not found' USING ERRCODE='P0002';
  END IF;

  IF l.character_id IS NULL THEN
    RAISE EXCEPTION 'Encounter character is unavailable' USING ERRCODE='23514';
  END IF;

  IF l.status='settled' OR l.status='cancelled'
     OR l.scheduled_end_at <= clock_timestamp() THEN
    RAISE EXCEPTION 'Encounter scene expired or closed' USING ERRCODE='23514';
  END IF;

  IF p_action='pause' THEN
    IF l.status='paused' THEN
      RETURN jsonb_build_object('session_id',p_session_id,'status','paused','idempotent',true);
    END IF;
    IF l.status <> 'active' THEN
      RAISE EXCEPTION 'Encounter session cannot be paused from current state' USING ERRCODE='23514';
    END IF;
    v_status := 'paused';
  ELSE
    IF l.status='active' THEN
      RETURN jsonb_build_object('session_id',p_session_id,'status','active','idempotent',true);
    END IF;
    IF l.status <> 'paused' THEN
      RAISE EXCEPTION 'Encounter session cannot be resumed from current state' USING ERRCODE='23514';
    END IF;
    v_status := 'active';
  END IF;

  UPDATE public.encounter_session_lifecycle
  SET status=v_status,updated_at=clock_timestamp()
  WHERE session_id=p_session_id;

  RETURN jsonb_build_object('session_id',p_session_id,'status',v_status,'idempotent',false);
END;
$$;

REVOKE ALL ON FUNCTION public.set_encounter_session_lifecycle_state(uuid,uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.set_encounter_session_lifecycle_state(uuid,uuid,text) TO service_role;

COMMENT ON FUNCTION public.set_encounter_session_lifecycle_state(uuid,uuid,text) IS
  'Owner-checked by the trusted Edge Function; pauses or resumes a scene without settling affinity. Paused sessions still become settleable at their scheduled end.';
