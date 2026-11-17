-- DRAFT TEST ONLY: whole-session Encounter evaluation queue and settlement smoke test.
-- Run only against the disposable local synthetic Supabase database.
-- This test does not call OpenRouter, touch a hosted project, or activate cron.

BEGIN;

SET LOCAL request.jwt.claim.role = 'service_role';

DO $encounter_evaluation_worker_smoke$
DECLARE
  v_user_id uuid := '00000000-0000-4000-8000-000000000020';
  v_character_id uuid := '00000000-0000-4000-8000-000000000021';
  v_session_id uuid := '00000000-0000-4000-8000-000000000022';
  v_incomplete_session_id uuid := '00000000-0000-4000-8000-000000000023';
  v_enqueued integer;
  v_claimed record;
  v_settlement jsonb;
  v_retry jsonb;
  v_job_status text;
  v_affinity integer;
  v_lifecycle_status text;
BEGIN
  INSERT INTO auth.users (
    id, aud, role, email, encrypted_password, created_at, updated_at
  ) VALUES (
    v_user_id, 'authenticated', 'authenticated',
    'encounter-evaluation-smoke@example.invalid', '',
    clock_timestamp(), clock_timestamp()
  );

  INSERT INTO public.profiles (id, handle, nickname)
  VALUES (v_user_id, 'encounter-eval-smoke', 'Encounter 評估測試');

  INSERT INTO public.characters (
    id, author_id, name, visibility, review_status, rights_confirmed
  ) VALUES (
    v_character_id, v_user_id, 'Encounter 評估測試角色', 'public', 'approved', true
  );

  INSERT INTO public.chat_sessions (
    id, user_id, character_id, character_name, status,
    character_snapshot, session_data, chat_mode
  ) VALUES
  (
    v_session_id, v_user_id, v_character_id, 'Encounter 評估測試角色', 'active',
    jsonb_build_object('id', v_character_id, 'name', 'Encounter 評估測試角色'),
    jsonb_build_object('encounter', jsonb_build_object('affinity', 0, 'relationshipStage', 'first_meeting')),
    'encounter'
  ),
  (
    v_incomplete_session_id, v_user_id, v_character_id, 'Encounter 評估測試角色', 'active',
    jsonb_build_object('id', v_character_id, 'name', 'Encounter 評估測試角色'),
    jsonb_build_object('encounter', jsonb_build_object('affinity', 0, 'relationshipStage', 'first_meeting')),
    'encounter'
  );

  INSERT INTO public.encounter_session_lifecycle (
    session_id, user_id, character_id, location_key, schedule_snapshot,
    scheduled_start_at, scheduled_end_at, status, turn_count
  ) VALUES
  (
    v_session_id, v_user_id, v_character_id, 'cafe', '{"activity":"測試結束場景"}'::jsonb,
    clock_timestamp() - interval '2 hours', clock_timestamp() + interval '2 hours',
    'active', 0
  ),
  (
    v_incomplete_session_id, v_user_id, v_character_id, 'park', '{"activity":"缺少回合證據"}'::jsonb,
    clock_timestamp() - interval '2 hours', clock_timestamp() - interval '1 minute',
    'active', 1
  );

  -- Explicit player end shortens the effective deadline but keeps the original schedule snapshot.
  PERFORM public.set_encounter_session_lifecycle_state(
    v_session_id, v_user_id, 'end'
  );
  IF NOT EXISTS (
    SELECT 1 FROM public.encounter_session_lifecycle
    WHERE session_id = v_session_id
      AND status = 'ready_to_settle'
      AND scheduled_end_at <= clock_timestamp()
      AND schedule_snapshot->>'scheduled_end_at' IS NULL
  ) THEN
    RAISE EXCEPTION 'manual Encounter end did not move the lifecycle into the due settlement state';
  END IF;

  -- Due, zero-turn sessions may settle neutrally; missing turn evidence must never enqueue.
  v_enqueued := public.enqueue_due_encounter_evaluations(50);
  IF v_enqueued <> 1 THEN
    RAISE EXCEPTION 'expected exactly one due complete Encounter job, got %', v_enqueued;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.encounter_session_evaluation_jobs
    WHERE session_id = v_incomplete_session_id
  ) THEN
    RAISE EXCEPTION 'session with incomplete turn evidence was enqueued';
  END IF;

  SELECT * INTO v_claimed
  FROM public.claim_encounter_evaluation_jobs(1);
  IF NOT FOUND OR v_claimed.session_id <> v_session_id OR v_claimed.attempt_count <> 1 THEN
    RAISE EXCEPTION 'due Encounter evaluation job was not claimed exactly once';
  END IF;

  v_settlement := public.settle_encounter_session(
    v_session_id,
    0,
    'first_meeting',
    '[]'::jsonb,
    jsonb_build_object('source', 'disposable_worker_smoke', 'turn_count', 0)
  );
  IF COALESCE((v_settlement->>'settled')::boolean, false) IS NOT TRUE
     OR COALESCE((v_settlement->>'idempotent')::boolean, true) IS NOT FALSE THEN
    RAISE EXCEPTION 'first Encounter settlement did not commit exactly once';
  END IF;

  v_retry := public.settle_encounter_session(
    v_session_id,
    20,
    'close',
    '[]'::jsonb,
    '{"source":"disposable_idempotency_retry"}'::jsonb
  );
  IF COALESCE((v_retry->>'settled')::boolean, false) IS NOT TRUE
     OR COALESCE((v_retry->>'idempotent')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'Encounter settlement retry was not idempotent';
  END IF;

  SELECT status INTO v_job_status
  FROM public.encounter_session_evaluation_jobs
  WHERE session_id = v_session_id;
  SELECT status, settlement_delta INTO v_lifecycle_status, v_affinity
  FROM public.encounter_session_lifecycle
  WHERE session_id = v_session_id;

  IF v_job_status <> 'completed' OR v_lifecycle_status <> 'settled' OR v_affinity <> 0 THEN
    RAISE EXCEPTION 'settlement/job completion mismatch: job %, lifecycle %, delta %',
      v_job_status, v_lifecycle_status, v_affinity;
  END IF;

  IF (
    SELECT affinity FROM public.encounter_character_state
    WHERE user_id = v_user_id AND character_id = v_character_id
  ) <> 0 THEN
    RAISE EXCEPTION 'idempotent retry changed affinity unexpectedly';
  END IF;
END;
$encounter_evaluation_worker_smoke$;

ROLLBACK;
