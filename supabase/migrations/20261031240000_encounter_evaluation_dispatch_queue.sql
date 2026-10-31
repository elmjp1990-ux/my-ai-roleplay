-- Queue due Encounter scenes for trusted whole-session evaluation.
-- This dispatcher never invents an affinity delta; it only makes complete, expired scenes claimable.
CREATE TABLE IF NOT EXISTS public.encounter_session_evaluation_jobs (
  session_id uuid PRIMARY KEY REFERENCES public.encounter_session_lifecycle(session_id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  character_id uuid REFERENCES public.characters(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','processing','completed','failed')),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  claimed_at timestamptz,
  completed_at timestamptz,
  last_error text CHECK (last_error IS NULL OR char_length(last_error) <= 500),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT encounter_evaluation_job_state_check CHECK (
    (status='processing' AND claimed_at IS NOT NULL)
    OR status <> 'processing'
  ),
  CONSTRAINT encounter_evaluation_job_completed_check CHECK (
    (status='completed' AND completed_at IS NOT NULL)
    OR status <> 'completed'
  )
);

CREATE INDEX IF NOT EXISTS encounter_evaluation_jobs_claim_idx
  ON public.encounter_session_evaluation_jobs(status,claimed_at,created_at)
  WHERE status IN ('pending','failed','processing');

ALTER TABLE public.encounter_session_evaluation_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.encounter_session_evaluation_jobs FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE public.encounter_session_evaluation_jobs TO service_role;

CREATE OR REPLACE FUNCTION public.validate_encounter_evaluation_job_link()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid;
  v_character_id uuid;
  v_chat_mode text;
BEGIN
  SELECT s.user_id,s.character_id,s.chat_mode
  INTO v_user_id,v_character_id,v_chat_mode
  FROM public.chat_sessions AS s
  WHERE s.id=NEW.session_id;

  IF NOT FOUND OR v_user_id IS DISTINCT FROM NEW.user_id
     OR v_chat_mode <> 'encounter'
     OR (NEW.character_id IS NOT NULL AND v_character_id IS DISTINCT FROM NEW.character_id) THEN
    RAISE EXCEPTION 'Encounter evaluation job session link is invalid' USING ERRCODE='23514';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.validate_encounter_evaluation_job_link() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS validate_encounter_evaluation_job_link ON public.encounter_session_evaluation_jobs;
CREATE TRIGGER validate_encounter_evaluation_job_link
  BEFORE INSERT OR UPDATE OF session_id,user_id,character_id
  ON public.encounter_session_evaluation_jobs
  FOR EACH ROW EXECUTE FUNCTION public.validate_encounter_evaluation_job_link();

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
    -- Never queue while a pre-expiry reservation can still produce a reply,
    -- or while a settled charge is still missing its evidence row.
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
      SET status='pending',claimed_at=NULL,last_error=NULL,updated_at=clock_timestamp()
      WHERE public.encounter_session_evaluation_jobs.status='failed';

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
      AND (
        job.status IN ('pending','failed')
        OR (job.status='processing' AND job.claimed_at < clock_timestamp()-interval '10 minutes')
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

CREATE OR REPLACE FUNCTION public.fail_encounter_evaluation_job(p_session_id uuid,p_error text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_updated integer;
BEGIN
  IF p_session_id IS NULL THEN
    RAISE EXCEPTION 'Invalid evaluation job session' USING ERRCODE='22023';
  END IF;

  UPDATE public.encounter_session_evaluation_jobs
  SET status='failed',claimed_at=NULL,last_error=left(COALESCE(p_error,'evaluation_failed'),500),
      updated_at=clock_timestamp()
  WHERE session_id=p_session_id AND status='processing';

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated=1;
END;
$$;

REVOKE ALL ON FUNCTION public.fail_encounter_evaluation_job(uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.fail_encounter_evaluation_job(uuid,text) TO service_role;

CREATE OR REPLACE FUNCTION public.mark_encounter_evaluation_job_completed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.status='settled' AND OLD.status IS DISTINCT FROM 'settled' THEN
    UPDATE public.encounter_session_evaluation_jobs
    SET status='completed',completed_at=clock_timestamp(),claimed_at=NULL,
        last_error=NULL,updated_at=clock_timestamp()
    WHERE session_id=NEW.session_id;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_encounter_evaluation_job_completed() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS mark_encounter_evaluation_job_completed ON public.encounter_session_lifecycle;
CREATE TRIGGER mark_encounter_evaluation_job_completed
  AFTER UPDATE OF status ON public.encounter_session_lifecycle
  FOR EACH ROW EXECUTE FUNCTION public.mark_encounter_evaluation_job_completed();

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

-- One-minute dispatcher: only enqueue eligible scenes; AI evaluation is a separate trusted worker.
DO $$
DECLARE
  v_job_id bigint;
BEGIN
  SELECT jobid INTO v_job_id
  FROM cron.job
  WHERE jobname='poyozz-encounter-evaluation-dispatch';
  IF v_job_id IS NOT NULL THEN
    PERFORM cron.unschedule(v_job_id);
  END IF;

  PERFORM cron.schedule(
    'poyozz-encounter-evaluation-dispatch',
    '* * * * *',
    'SELECT public.enqueue_due_encounter_evaluations(50);'
  );
END;
$$;

COMMENT ON TABLE public.encounter_session_evaluation_jobs IS
  'Private queue of expired Encounter sessions ready for whole-session AI evaluation. The dispatcher never invents affinity values; a trusted evaluator must call the idempotent settlement RPC.';
