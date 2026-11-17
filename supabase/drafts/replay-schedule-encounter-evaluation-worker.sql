-- DRAFT TEST ONLY: scheduler function remains disabled and does not create cron jobs.
-- Run only against the disposable local synthetic Supabase database.

BEGIN;
SET LOCAL request.jwt.claim.role = 'service_role';

DO $encounter_evaluation_scheduler_smoke$
DECLARE
  v_status text;
  v_rejected boolean := false;
  v_job_exists boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claim.role', '', true);
  BEGIN
    PERFORM public.schedule_encounter_evaluation_worker(false);
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'scheduler accepted a request without the service role';
  END IF;

  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  v_status := public.schedule_encounter_evaluation_worker(false);
  IF v_status NOT IN ('disabled', 'scheduler_extensions_missing') THEN
    RAISE EXCEPTION 'unexpected disabled scheduler response: %', v_status;
  END IF;

  IF to_regclass('cron.job') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM cron.job WHERE jobname = $1)'
      INTO v_job_exists
      USING 'poyozz-encounter-evaluation-worker';
  END IF;
  IF v_job_exists THEN
    RAISE EXCEPTION 'Encounter evaluation cron must remain disabled in local smoke test';
  END IF;
END;
$encounter_evaluation_scheduler_smoke$;

ROLLBACK;
