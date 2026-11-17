-- DRAFT TEST ONLY: scheduler function remains disabled and does not create cron jobs.
-- Run only against the disposable local synthetic Supabase database.

BEGIN;
SET LOCAL request.jwt.claim.role = 'service_role';

DO $encounter_evaluation_scheduler_smoke$
DECLARE
  v_status text;
BEGIN
  v_status := public.schedule_encounter_evaluation_worker(false);
  IF v_status NOT IN ('disabled', 'scheduler_extensions_missing') THEN
    RAISE EXCEPTION 'unexpected disabled scheduler response: %', v_status;
  END IF;

  IF to_regclass('cron.job') IS NOT NULL AND EXISTS (
    SELECT 1 FROM cron.job
    WHERE jobname = 'poyozz-encounter-evaluation-worker'
  ) THEN
    RAISE EXCEPTION 'Encounter evaluation cron must remain disabled in local smoke test';
  END IF;
END;
$encounter_evaluation_scheduler_smoke$;

ROLLBACK;
