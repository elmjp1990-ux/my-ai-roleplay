-- DRAFT ONLY: allow the player to end an Encounter before its scheduled slot expires.
-- The original schedule window remains preserved in schedule_snapshot; scheduled_end_at
-- becomes the effective settlement deadline so the existing queue/worker can run immediately.

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
  v_effective_end timestamptz;
BEGIN
  IF p_session_id IS NULL OR p_user_id IS NULL OR p_action IS NULL
     OR p_action NOT IN ('pause','resume','end') THEN
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

  IF p_action='end' THEN
    IF l.status='settled' THEN
      RETURN jsonb_build_object(
        'session_id',p_session_id,'status','settled','idempotent',true
      );
    END IF;
    IF l.status='cancelled' THEN
      RAISE EXCEPTION 'Encounter scene is closed' USING ERRCODE='23514';
    END IF;
    IF l.status='ready_to_settle' THEN
      RETURN jsonb_build_object(
        'session_id',p_session_id,'status','ready_to_settle','idempotent',true,
        'scheduled_end_at',l.scheduled_end_at
      );
    END IF;
    IF l.status NOT IN ('active','paused') THEN
      RAISE EXCEPTION 'Encounter session cannot be ended from current state' USING ERRCODE='23514';
    END IF;

    -- Preserve the original planned slot in schedule_snapshot. The lifecycle
    -- deadline is shortened only to the actual end request, never before start.
    v_effective_end := LEAST(
      l.scheduled_end_at,
      GREATEST(pg_catalog.clock_timestamp(), l.scheduled_start_at + interval '1 second')
    );
    UPDATE public.encounter_session_lifecycle
    SET status='ready_to_settle',
        scheduled_end_at=v_effective_end,
        updated_at=pg_catalog.clock_timestamp()
    WHERE session_id=p_session_id;

    RETURN jsonb_build_object(
      'session_id',p_session_id,'status','ready_to_settle','idempotent',false,
      'scheduled_end_at',v_effective_end,'endRequested',true
    );
  END IF;

  IF l.status='settled' OR l.status='cancelled'
     OR l.scheduled_end_at <= pg_catalog.clock_timestamp() THEN
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
  SET status=v_status,updated_at=pg_catalog.clock_timestamp()
  WHERE session_id=p_session_id;

  RETURN jsonb_build_object('session_id',p_session_id,'status',v_status,'idempotent',false);
END;
$$;

REVOKE ALL ON FUNCTION public.set_encounter_session_lifecycle_state(uuid,uuid,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.set_encounter_session_lifecycle_state(uuid,uuid,text)
  TO service_role;

COMMENT ON FUNCTION public.set_encounter_session_lifecycle_state(uuid,uuid,text) IS
  'Owner-checked by the trusted Edge Function. Pause/resume preserve the scheduled window; explicit end moves the lifecycle to ready_to_settle immediately while preserving the original slot in schedule_snapshot.';
