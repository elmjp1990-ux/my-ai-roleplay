-- DRAFT ONLY: stage-aware Encounter opening greeting selection.
-- Apply only after encounter-schedule-pipeline.sql has created the greeting-pool table.
-- This draft is not a hosted migration and does not deploy or enable any worker.

CREATE TABLE IF NOT EXISTS public.encounter_character_greeting_history (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  character_id uuid NOT NULL REFERENCES public.characters(id) ON DELETE CASCADE,
  last_greeting_hash text CHECK (
    last_greeting_hash IS NULL OR last_greeting_hash ~ '^[0-9a-f]{32}$'
  ),
  last_relationship_stage text CHECK (
    last_relationship_stage IS NULL OR last_relationship_stage IN (
      'hostile', 'dislike', 'wary', 'first_meeting',
      'acquaintance', 'close', 'intimate', 'special'
    )
  ),
  last_session_id uuid REFERENCES public.chat_sessions(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  PRIMARY KEY (user_id, character_id)
);

ALTER TABLE public.encounter_character_greeting_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.encounter_character_greeting_history FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_character_greeting_history TO service_role;

COMMENT ON TABLE public.encounter_character_greeting_history IS
  'Service-only per-player/per-character last greeting hash. Used to avoid repeating the immediately previous Encounter opening across sessions.';

-- One-time, explicitly invoked backfill for already-published characters.
-- The queue retains its existing global batch cooldown and daily rate limits.
CREATE OR REPLACE FUNCTION public.queue_encounter_greeting_pool_backfill(
  p_limit integer DEFAULT 1000
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 1000), 1), 1000);
  v_character_id uuid;
  v_result jsonb;
  v_queued integer := 0;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  FOR v_character_id IN
    SELECT c.id
    FROM public.characters AS c
    CROSS JOIN LATERAL (
      SELECT public.encounter_schedule_source_payload(c.id) AS payload
    ) AS source
    WHERE source.payload IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM public.character_schedules AS schedule
        WHERE schedule.character_id = c.id
          AND schedule.is_active IS TRUE
          AND schedule.source_type IN ('ai', 'legacy', 'manual')
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.encounter_character_greeting_pools AS pool
        WHERE pool.character_id = c.id
          AND pool.source_hash = pg_catalog.md5(source.payload::text)
      )
    ORDER BY c.created_at, c.id
    FOR UPDATE OF c SKIP LOCKED
    LIMIT v_limit
  LOOP
    v_result := public.enqueue_encounter_schedule_generation_internal(v_character_id);
    IF v_result->>'status' = 'pending' THEN
      v_queued := v_queued + 1;
    END IF;
  END LOOP;

  RETURN pg_catalog.jsonb_build_object(
    'queued_count', v_queued,
    'limit', v_limit,
    'scheduler', 'existing_global_rate_limits'
  );
END;
$;

REVOKE ALL ON FUNCTION public.queue_encounter_greeting_pool_backfill(integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.queue_encounter_greeting_pool_backfill(integer)
  TO service_role;

COMMENT ON FUNCTION public.queue_encounter_greeting_pool_backfill(integer) IS
  'Explicit one-time backfill for already-published characters with active schedules but no current relationship-stage greeting pool. Never runs automatically; the existing global schedule batch cooldown and daily limits remain in force.';

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
  v_affinity integer := 0;
  v_relationship_stage text := 'first_meeting';
  v_stage_pool jsonb;
  v_last_greeting_hash text;
  v_greeting text;
  v_greeting_hash text;
  v_greeting_id text;
  v_snapshot jsonb;
  v_session_data jsonb;
  v_session jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF p_session_id IS NULL OR p_user_id IS NULL OR p_character_id IS NULL
     OR p_location_key IS NULL OR char_length(p_location_key) NOT BETWEEN 1 AND 80
     OR jsonb_typeof(COALESCE(p_character_snapshot, '{}'::jsonb)) <> 'object'
     OR jsonb_typeof(COALESCE(p_schedule_snapshot, '{}'::jsonb)) <> 'object'
     OR pg_column_size(COALESCE(p_schedule_snapshot, '{}'::jsonb)) > 8000
     OR p_scheduled_start_at IS NULL OR p_scheduled_end_at IS NULL
     OR p_scheduled_end_at <= p_scheduled_start_at THEN
    RAISE EXCEPTION 'Invalid Encounter session lifecycle input' USING ERRCODE = '22023';
  END IF;

  SELECT state.affinity, state.relationship_stage
  INTO v_affinity, v_relationship_stage
  FROM public.encounter_character_state AS state
  WHERE state.user_id = p_user_id
    AND state.character_id = p_character_id;

  IF NOT FOUND THEN
    v_affinity := 0;
    v_relationship_stage := 'first_meeting';
  END IF;
  v_affinity := COALESCE(v_affinity, 0);
  IF COALESCE(v_relationship_stage, '') NOT IN (
    'hostile', 'dislike', 'wary', 'first_meeting',
    'acquaintance', 'close', 'intimate', 'special'
  ) THEN
    v_relationship_stage := 'first_meeting';
  END IF;

  SELECT pools.greeting_pools -> v_relationship_stage
  INTO v_stage_pool
  FROM public.encounter_character_greeting_pools AS pools
  WHERE pools.character_id = p_character_id;

  IF CASE
       WHEN jsonb_typeof(v_stage_pool) = 'array'
       THEN jsonb_array_length(v_stage_pool) BETWEEN 3 AND 5
       ELSE false
     END THEN
    INSERT INTO public.encounter_character_greeting_history (
      user_id, character_id
    ) VALUES (p_user_id, p_character_id)
    ON CONFLICT (user_id, character_id) DO NOTHING;

    SELECT history.last_greeting_hash
    INTO v_last_greeting_hash
    FROM public.encounter_character_greeting_history AS history
    WHERE history.user_id = p_user_id
      AND history.character_id = p_character_id
    FOR UPDATE;

    SELECT greeting.value #>> '{}'
    INTO v_greeting
    FROM jsonb_array_elements(v_stage_pool) AS greeting(value)
    WHERE pg_catalog.md5(greeting.value #>> '{}') IS DISTINCT FROM v_last_greeting_hash
    ORDER BY pg_catalog.random()
    LIMIT 1;

    -- A valid pool has at least three unique options. This is a defensive fallback
    -- in case a manually edited pool bypassed the publisher's validation.
    IF v_greeting IS NULL THEN
      SELECT greeting.value #>> '{}'
      INTO v_greeting
      FROM jsonb_array_elements(v_stage_pool) AS greeting(value)
      ORDER BY pg_catalog.random()
      LIMIT 1;
    END IF;

    IF COALESCE(char_length(v_greeting), 0) NOT BETWEEN 150 AND 300 THEN
      RAISE EXCEPTION 'Encounter relationship greeting pool is invalid' USING ERRCODE = '23514';
    END IF;

    v_greeting_hash := pg_catalog.md5(v_greeting);
    v_greeting_id := v_relationship_stage || ':' || v_greeting_hash;

  ELSE
    -- Legacy schedules remain usable until their character's new greeting pools publish.
    v_greeting := COALESCE(p_character_snapshot->>'encounterGreeting', '');
    v_greeting_id := CASE WHEN v_greeting <> '' THEN 'schedule:' || pg_catalog.md5(v_greeting) ELSE NULL END;
  END IF;

  v_snapshot := COALESCE(p_character_snapshot, '{}'::jsonb) ||
    jsonb_build_object(
      'encounterGreeting', v_greeting,
      'encounterGreetingId', v_greeting_id,
      'encounterRelationshipStage', v_relationship_stage
    );
  v_session_data := jsonb_build_object(
    'encounter',
    jsonb_build_object(
      'affinity', v_affinity,
      'relationshipStage', v_relationship_stage,
      'greetingId', v_greeting_id,
      'greetingText', v_greeting
    )
  );

  INSERT INTO public.chat_sessions (
    id, user_id, character_id, character_name, status,
    character_snapshot, session_data, chat_mode
  ) VALUES (
    p_session_id, p_user_id, p_character_id, p_character_name, 'active',
    v_snapshot, v_session_data, 'encounter'
  );

  IF v_greeting_hash IS NOT NULL THEN
    UPDATE public.encounter_character_greeting_history
    SET last_greeting_hash = v_greeting_hash,
        last_relationship_stage = v_relationship_stage,
        last_session_id = p_session_id,
        updated_at = pg_catalog.clock_timestamp()
    WHERE user_id = p_user_id
      AND character_id = p_character_id;
  END IF;

  INSERT INTO public.encounter_session_lifecycle (
    session_id, user_id, character_id, location_key, schedule_snapshot,
    scheduled_start_at, scheduled_end_at, timezone, status
  ) VALUES (
    p_session_id, p_user_id, p_character_id, p_location_key, p_schedule_snapshot,
    p_scheduled_start_at, p_scheduled_end_at, 'Asia/Taipei', 'active'
  );

  SELECT jsonb_build_object(
    'id', s.id, 'user_id', s.user_id, 'character_id', s.character_id,
    'character_name', s.character_name, 'status', s.status,
    'character_snapshot', s.character_snapshot, 'session_data', s.session_data,
    'chat_mode', s.chat_mode, 'created_at', s.created_at, 'updated_at', s.updated_at
  ) INTO v_session
  FROM public.chat_sessions AS s WHERE s.id = p_session_id;
  RETURN v_session;
END;
$$;

REVOKE ALL ON FUNCTION public.create_encounter_session_with_lifecycle(
  uuid, uuid, uuid, text, jsonb, jsonb, text, timestamptz, timestamptz
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_encounter_session_with_lifecycle(
  uuid, uuid, uuid, text, jsonb, jsonb, text, timestamptz, timestamptz
) TO service_role;

COMMENT ON FUNCTION public.create_encounter_session_with_lifecycle(
  uuid, uuid, uuid, text, jsonb, jsonb, text, timestamptz, timestamptz
) IS
  'Creates an Encounter session with current relationship state, stage-specific randomized opening greeting, per-player no-immediate-repeat history, and immutable schedule snapshot.';
