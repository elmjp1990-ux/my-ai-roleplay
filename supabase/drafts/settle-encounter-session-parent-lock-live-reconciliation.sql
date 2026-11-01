-- DRAFT ONLY — live test-project settlement parent-lock reconciliation.
-- Do not apply directly to a hosted database.
-- Reviewed against live test function on 2026-11-02.
--
-- Purpose:
--   Serialize Encounter settlement against chat deletion using the same lock
--   order as deletion and encounter writers: chat_sessions parent first,
--   encounter_session_lifecycle second, relationship state last.
--
-- Live function signature and ACL observed:
--   public.settle_encounter_session(uuid, integer, text, jsonb, jsonb)
--   owner postgres; EXECUTE postgres + service_role only.
--
-- This replacement preserves SECURITY DEFINER, empty search_path, signature,
-- payload validation, pending-charge guard, evidence-count guard, affinity
-- clamping, and idempotency. It adds the deleted-parent gate before lifecycle
-- lock and before idempotent return.
--
-- Important: This file is a review artifact, not a migration. Validate against
-- the current PR head and test locally before moving it into migrations.

CREATE OR REPLACE FUNCTION public.settle_encounter_session(
  p_session_id uuid,
  p_affinity_delta integer,
  p_relationship_stage text,
  p_memories jsonb DEFAULT '[]'::jsonb,
  p_evaluation jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  l public.encounter_session_lifecycle%ROWTYPE;
  v_current integer := 0;
  v_final integer := 0;
  v_state_id uuid;
  v_result jsonb;
BEGIN
  IF p_session_id IS NULL OR p_affinity_delta IS NULL
     OR p_affinity_delta NOT BETWEEN -100 AND 100
     OR p_relationship_stage IS NULL
     OR p_relationship_stage NOT IN (
       'hostile','dislike','wary','first_meeting',
       'acquaintance','close','intimate','special'
     )
     OR jsonb_typeof(COALESCE(p_memories,'[]'::jsonb)) <> 'array'
     OR pg_column_size(COALESCE(p_memories,'[]'::jsonb)) > 20000
     OR jsonb_typeof(COALESCE(p_evaluation,'{}'::jsonb)) <> 'object'
     OR pg_column_size(COALESCE(p_evaluation,'{}'::jsonb)) > 12000 THEN
    RAISE EXCEPTION 'Invalid Encounter settlement payload' USING ERRCODE='22023';
  END IF;

  -- Must be the first row lock. Chat deletion locks this same parent.
  -- The parent gate precedes even the already-settled idempotent return.
  PERFORM 1
  FROM public.chat_sessions AS s
  WHERE s.id = p_session_id
    AND s.chat_mode = 'encounter'
    AND s.deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Encounter session is deleted or inaccessible'
      USING ERRCODE='23514';
  END IF;

  SELECT * INTO l
  FROM public.encounter_session_lifecycle
  WHERE session_id = p_session_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Encounter lifecycle not found' USING ERRCODE='P0002';
  END IF;

  IF l.status = 'settled' THEN
    RETURN jsonb_build_object(
      'settled',true,'idempotent',true,'result',l.settlement_result
    );
  END IF;
  IF l.character_id IS NULL THEN
    RAISE EXCEPTION
      'Encounter character is no longer available for relationship settlement'
      USING ERRCODE='23514';
  END IF;
  IF l.status NOT IN ('active','paused','ready_to_settle')
     OR l.scheduled_end_at > clock_timestamp() THEN
    RAISE EXCEPTION
      'Encounter scene has not reached scheduled end or is not settleable'
      USING ERRCODE='23514';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.chat_turn_charges AS c
    WHERE c.session_id = p_session_id
      AND c.reserved_at IS NOT NULL
      AND c.reserved_at <= l.scheduled_end_at
      AND c.status IN ('reserved','needs_reconciliation')
  ) THEN
    RAISE EXCEPTION 'Encounter has pending pre-expiry turns'
      USING ERRCODE='23514';
  END IF;

  IF (
    SELECT count(*) FROM public.encounter_session_turns AS t
    WHERE t.session_id = p_session_id
  ) <> l.turn_count THEN
    RAISE EXCEPTION 'Encounter turn evidence is incomplete'
      USING ERRCODE='23514';
  END IF;

  INSERT INTO public.encounter_character_state(
    user_id,character_id,affinity,relationship_stage,
    first_met_at,last_interaction_at
  )
  VALUES(
    l.user_id,l.character_id,0,'first_meeting',
    clock_timestamp(),clock_timestamp()
  )
  ON CONFLICT (user_id,character_id) DO NOTHING;

  SELECT s.id,s.affinity INTO v_state_id,v_current
  FROM public.encounter_character_state AS s
  WHERE s.user_id = l.user_id AND s.character_id = l.character_id
  FOR UPDATE;

  v_final := greatest(-100,least(100,v_current+p_affinity_delta));
  UPDATE public.encounter_character_state
  SET affinity = v_final,
      relationship_stage = p_relationship_stage,
      last_interaction_at = clock_timestamp(),
      updated_at = clock_timestamp()
  WHERE id = v_state_id;

  v_result := jsonb_build_object(
    'final_affinity',v_final,
    'affinity_delta',v_final-v_current,
    'relationship_stage',p_relationship_stage,
    'memories',COALESCE(p_memories,'[]'::jsonb),
    'evaluation',COALESCE(p_evaluation,'{}'::jsonb),
    'turn_count',l.turn_count,
    'source_session_id',p_session_id
  );

  UPDATE public.encounter_session_lifecycle
  SET status = 'settled',
      settlement_delta = v_final-v_current,
      settlement_result = v_result,
      settled_at = clock_timestamp(),
      updated_at = clock_timestamp()
  WHERE session_id = p_session_id;

  RETURN jsonb_build_object(
    'settled',true,'idempotent',false,'result',v_result
  );
END;
$function$;

-- Preserve the observed live EXECUTE audience; do not leave default PUBLIC.
REVOKE ALL ON FUNCTION public.settle_encounter_session(
  uuid, integer, text, jsonb, jsonb
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.settle_encounter_session(
  uuid, integer, text, jsonb, jsonb
) TO service_role;

-- Required verification before promotion to a migration:
-- 1. Function owner remains postgres; SECURITY DEFINER and search_path='' remain.
-- 2. EXECUTE is available to postgres/service_role only; no PUBLIC/anon/authenticated.
-- 3. Deleted parent fails before lifecycle read/lock and before idempotent return.
-- 4. Active parent + due lifecycle settles once; second call is idempotent.
-- 5. Pending pre-expiry reservation blocks settlement without affinity changes.
-- 6. Incomplete turn evidence blocks settlement without affinity changes.
-- 7. Lock order is parent -> lifecycle -> encounter_character_state.
--
-- Concurrency fixtures (run only in disposable local DB, inside rollback):
-- A. Delete transaction locks chat_sessions first; settlement blocks, then sees
--    deleted_at after delete commits and raises; assert affinity/lifecycle unchanged.
-- B. Settlement locks chat_sessions first; delete blocks; settlement commits;
--    delete then marks parent deleted; assert one settlement and deletion wins
--    for all subsequent calls.
-- C. Already-settled lifecycle with deleted parent must still raise, not return
--    idempotent success.
-- D. Non-Encounter chat session ID must raise and must not mutate any row.
--
-- Do not test races by concurrent sessions against a shared/non-disposable DB.
