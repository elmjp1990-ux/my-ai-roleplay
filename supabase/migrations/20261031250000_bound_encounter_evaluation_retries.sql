-- Bound evaluation job retries to avoid a cron-driven retry storm.
CREATE OR REPLACE FUNCTION public.enqueue_due_encounter_evaluations(p_limit integer DEFAULT 50)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  l public.encounter_session_lifecycle%ROWTYPE;
  v_enqueued integer := 0;
  v_rows integer := 0;
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit,50),1),100);
BEGIN
  FOR l IN
    SELECT lifecycle.*
    FROM public.encounter_session_lifecycle AS lifecycle
    WHERE lifecycle.status IN ('active','paused','ready_to_settle')
      AND lifecycle.character_id IS NOT NULL
      AND lifecycle.scheduled_end_at <= clock_timestamp()
    ORDER BY lifecycle.scheduled_end_at,lifecycle.session_id
    FOR UPDATE SKIP LOCKED
    LIMIT v_limit
  LOOP
    IF EXISTS (
      SELECT 1 FROM public.chat_turn_charges AS charge
      WHERE charge.session_id=l.session_id
        AND charge.status IN ('created','reserved','needs_reconciliation')
    ) THEN
      CONTINUE;
    END IF;

    IF (
      SELECT count(*) FROM public.encounter_session_turns AS turn
      WHERE turn.session_id=l.session_id
    ) <> l.turn_count THEN
      CONTINUE;
    END IF;

    UPDATE public.encounter_session_lifecycle
    SET status='ready_to_settle',updated_at=clock_timestamp()
    WHERE session_id=l.session_id
      AND status IN ('active','paused','ready_to_settle');

    INSERT INTO public.encounter_session_evaluation_jobs(session_id,user_id,character_id,status)
    VALUES(l.session_id,l.user_id,l.character_id,'pending')
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
$$;

REVOKE ALL ON FUNCTION public.enqueue_due_encounter_evaluations(integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.enqueue_due_encounter_evaluations(integer) TO service_role;

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
AS $$
DECLARE
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit,10),1),25);
BEGIN
  RETURN QUERY
  WITH candidates AS (
    SELECT job.session_id
    FROM public.encounter_session_evaluation_jobs AS job
    JOIN public.encounter_session_lifecycle AS lifecycle
      ON lifecycle.session_id=job.session_id
    WHERE lifecycle.status='ready_to_settle'
      AND lifecycle.scheduled_end_at <= clock_timestamp()
      AND job.attempt_count < 5
      AND (
        job.status='pending'
        OR (
          job.status='failed'
          AND job.updated_at <= clock_timestamp()-interval '5 minutes'
        )
        OR (
          job.status='processing'
          AND job.claimed_at < clock_timestamp()-interval '10 minutes'
        )
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.chat_turn_charges AS charge
        WHERE charge.session_id=job.session_id
          AND charge.status IN ('created','reserved','needs_reconciliation')
      )
      AND (
        SELECT count(*) FROM public.encounter_session_turns AS turn
        WHERE turn.session_id=job.session_id
      ) = lifecycle.turn_count
    ORDER BY lifecycle.scheduled_end_at,job.session_id
    FOR UPDATE OF job SKIP LOCKED
    LIMIT v_limit
  )
  UPDATE public.encounter_session_evaluation_jobs AS job
  SET status='processing',attempt_count=job.attempt_count+1,
      claimed_at=clock_timestamp(),completed_at=NULL,last_error=NULL,updated_at=clock_timestamp()
  FROM candidates
  JOIN public.encounter_session_lifecycle AS lifecycle
    ON lifecycle.session_id=candidates.session_id
  WHERE job.session_id=candidates.session_id
  RETURNING job.session_id,job.user_id,job.character_id,lifecycle.turn_count,job.attempt_count;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_encounter_evaluation_jobs(integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.claim_encounter_evaluation_jobs(integer) TO service_role;

COMMENT ON FUNCTION public.claim_encounter_evaluation_jobs(integer) IS
  'Claims due Encounter evaluation jobs with a 10-minute lease, five-attempt maximum, and five-minute retry backoff.';
