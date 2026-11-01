-- DRAFT ONLY — PR #200 follow-up.
-- The existing encounter evaluation dispatcher/claimer only inspects
-- encounter_session_lifecycle. Chat purge clears lifecycle payload and deletes
-- the current evaluation job, but leaves the lifecycle row. Without checking
-- chat_sessions.deleted_at, the minute dispatcher can enqueue that deleted
-- encounter again after chat purge.
--
-- Do not apply until clean local replay and worker/settlement race tests pass.

CREATE OR REPLACE FUNCTION public.enqueue_due_encounter_evaluations(p_limit integer DEFAULT 50)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_session_id uuid;
  v_lifecycle public.encounter_session_lifecycle%ROWTYPE;
  v_session public.chat_sessions%ROWTYPE;
  v_rows integer;
  v_enqueued integer := 0;
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit,50),1),100);
BEGIN
  FOR v_session_id IN
    SELECT lifecycle.session_id
    FROM public.encounter_session_lifecycle lifecycle
    JOIN public.chat_sessions session ON session.id=lifecycle.session_id
    WHERE session.deleted_at IS NULL
      AND lifecycle.status IN ('active','paused','ready_to_settle')
      AND lifecycle.character_id IS NOT NULL
      AND lifecycle.scheduled_end_at <= clock_timestamp()
    ORDER BY lifecycle.scheduled_end_at,lifecycle.session_id
    LIMIT v_limit
  LOOP
    -- Global order: chat parent first, then lifecycle, then evaluation job.
    SELECT * INTO v_session
    FROM public.chat_sessions
    WHERE id=v_session_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN CONTINUE; END IF;

    SELECT * INTO v_lifecycle
    FROM public.encounter_session_lifecycle
    WHERE session_id=v_session_id
    FOR UPDATE;
    IF NOT FOUND
       OR v_lifecycle.status NOT IN ('active','paused','ready_to_settle')
       OR v_lifecycle.scheduled_end_at > clock_timestamp()
       OR v_lifecycle.character_id IS NULL THEN
      CONTINUE;
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.chat_turn_charges charge
      WHERE charge.session_id=v_session_id
        AND charge.status IN ('created','reserved','needs_reconciliation')
    ) THEN CONTINUE; END IF;

    IF (SELECT count(*) FROM public.encounter_session_turns turn
        WHERE turn.session_id=v_session_id) <> v_lifecycle.turn_count THEN
      CONTINUE;
    END IF;

    UPDATE public.encounter_session_lifecycle
    SET status='ready_to_settle',updated_at=clock_timestamp()
    WHERE session_id=v_session_id
      AND status IN ('active','paused','ready_to_settle');

    INSERT INTO public.encounter_session_evaluation_jobs(session_id,user_id,character_id,status)
    VALUES(v_session_id,v_lifecycle.user_id,v_lifecycle.character_id,'pending')
    ON CONFLICT (session_id) DO UPDATE
      SET status='pending',claimed_at=NULL,completed_at=NULL,last_error=NULL,updated_at=clock_timestamp()
      WHERE public.encounter_session_evaluation_jobs.status='failed'
        AND public.encounter_session_evaluation_jobs.attempt_count < 5
        AND public.encounter_session_evaluation_jobs.updated_at <= clock_timestamp()-interval '5 minutes';

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_enqueued := v_enqueued + v_rows;
  END LOOP;
  RETURN v_enqueued;
END;
$function$;

CREATE OR REPLACE FUNCTION public.claim_encounter_evaluation_jobs(p_limit integer DEFAULT 10)
RETURNS TABLE(
  session_id uuid,
  user_id uuid,
  character_id uuid,
  turn_count integer,
  attempt_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_session_id uuid;
  v_job public.encounter_session_evaluation_jobs%ROWTYPE;
  v_lifecycle public.encounter_session_lifecycle%ROWTYPE;
  v_session public.chat_sessions%ROWTYPE;
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit,10),1),25);
BEGIN
  FOR v_session_id IN
    SELECT job.session_id
    FROM public.encounter_session_evaluation_jobs job
    JOIN public.encounter_session_lifecycle lifecycle
      ON lifecycle.session_id=job.session_id
    JOIN public.chat_sessions session ON session.id=job.session_id
    WHERE session.deleted_at IS NULL
      AND lifecycle.status='ready_to_settle'
      AND lifecycle.scheduled_end_at <= clock_timestamp()
      AND job.attempt_count < 5
      AND (
        job.status='pending'
        OR (job.status='failed' AND job.updated_at <= clock_timestamp()-interval '5 minutes')
        OR (job.status='processing' AND job.claimed_at < clock_timestamp()-interval '10 minutes')
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.chat_turn_charges charge
        WHERE charge.session_id=job.session_id
          AND charge.status IN ('created','reserved','needs_reconciliation')
      )
      AND (SELECT count(*) FROM public.encounter_session_turns turn
           WHERE turn.session_id=job.session_id)=lifecycle.turn_count
    ORDER BY lifecycle.scheduled_end_at,job.session_id
    LIMIT v_limit
  LOOP
    -- Parent-first locking avoids inversion with chat deletion/purge.
    SELECT * INTO v_session FROM public.chat_sessions
    WHERE id=v_session_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN CONTINUE; END IF;

    SELECT * INTO v_lifecycle FROM public.encounter_session_lifecycle
    WHERE session_id=v_session_id AND status='ready_to_settle'
    FOR UPDATE;
    IF NOT FOUND OR v_lifecycle.scheduled_end_at > clock_timestamp() THEN CONTINUE; END IF;

    SELECT * INTO v_job FROM public.encounter_session_evaluation_jobs
    WHERE session_id=v_session_id
      AND attempt_count < 5
      AND (
        status='pending'
        OR (status='failed' AND updated_at <= clock_timestamp()-interval '5 minutes')
        OR (status='processing' AND claimed_at < clock_timestamp()-interval '10 minutes')
      )
    FOR UPDATE;
    IF NOT FOUND THEN CONTINUE; END IF;

    UPDATE public.encounter_session_evaluation_jobs
    SET status='processing',attempt_count=attempt_count+1,
        claimed_at=clock_timestamp(),completed_at=NULL,last_error=NULL,updated_at=clock_timestamp()
    WHERE encounter_session_evaluation_jobs.session_id=v_session_id
    RETURNING * INTO v_job;

    session_id:=v_job.session_id;
    user_id:=v_job.user_id;
    character_id:=v_job.character_id;
    turn_count:=v_lifecycle.turn_count;
    attempt_count:=v_job.attempt_count;
    RETURN NEXT;
  END LOOP;
END;
$function$;

-- Preserve the service-only execution boundary of the current functions.
REVOKE ALL ON FUNCTION public.enqueue_due_encounter_evaluations(integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.enqueue_due_encounter_evaluations(integer) TO service_role;
REVOKE ALL ON FUNCTION public.claim_encounter_evaluation_jobs(integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.claim_encounter_evaluation_jobs(integer) TO service_role;

-- Required tests:
-- 1. purge deletes an evaluation job; later dispatcher must not recreate it.
-- 2. dispatcher obtains session lock first; deletion waits, then removes job.
-- 3. deletion obtains session lock first; dispatcher waits and sees deleted_at.
-- 4. claim skips deleted session and never returns it to evaluator.
-- 5. evaluator/settlement RPC rechecks deleted_at while holding session parent
--    lock (claim-time filtering alone cannot prevent deletion after claim).
-- 6. retry/lease behavior remains bounded and idempotent for active sessions.
-- 7. verify existing pg_cron dispatcher still calls this function unchanged;
--    this proposal does not add or modify any chat-deletion cron.
