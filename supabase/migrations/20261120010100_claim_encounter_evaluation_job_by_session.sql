-- Claim exactly one requested Encounter evaluation job without draining other users' backlog.
CREATE OR REPLACE FUNCTION public.claim_encounter_evaluation_job(p_session_id uuid)
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
BEGIN
  RETURN QUERY
  WITH candidate AS (
    SELECT job.session_id
    FROM public.encounter_session_evaluation_jobs AS job
    JOIN public.encounter_session_lifecycle AS lifecycle
      ON lifecycle.session_id=job.session_id
    WHERE job.session_id=p_session_id
      AND lifecycle.status='ready_to_settle'
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
    FOR UPDATE OF job,lifecycle SKIP LOCKED
    LIMIT 1
  )
  UPDATE public.encounter_session_evaluation_jobs AS job
  SET status='processing',attempt_count=job.attempt_count+1,
      claimed_at=clock_timestamp(),completed_at=NULL,last_error=NULL,updated_at=clock_timestamp()
  FROM candidate
  JOIN public.encounter_session_lifecycle AS lifecycle
    ON lifecycle.session_id=candidate.session_id
  WHERE job.session_id=candidate.session_id
  RETURNING job.session_id,job.user_id,job.character_id,lifecycle.turn_count,job.attempt_count;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_encounter_evaluation_job(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.claim_encounter_evaluation_job(uuid) TO service_role;

COMMENT ON FUNCTION public.claim_encounter_evaluation_job(uuid) IS
  'Claims only the specified due Encounter evaluation job, preserving retry limits and avoiding unrelated queue backlog.';
