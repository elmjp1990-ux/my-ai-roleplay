-- Keep pg_cron execution history bounded instead of allowing cron.job_run_details
-- to grow indefinitely. Supabase does not automatically purge this managed history.
--
-- Retention: 7 days. Only scheduler execution metadata is deleted; application
-- data, cron.job definitions, and active schedules are not modified.
--
-- A normal DELETE makes old row space reusable after vacuum; it does not promise
-- an immediate reduction in the physical database size shown by the dashboard.
-- Do not run VACUUM FULL here (it rewrites/locks the table).
--
-- This migration is code only until explicitly applied to the hosted project.

DO $migration$
DECLARE
  v_job_id bigint;
BEGIN
  IF to_regclass('cron.job') IS NULL
     OR to_regclass('cron.job_run_details') IS NULL
     OR to_regprocedure('cron.schedule(text,text,text)') IS NULL
     OR to_regprocedure('cron.unschedule(bigint)') IS NULL THEN
    RAISE EXCEPTION 'pg_cron_history_retention_prerequisites_missing';
  END IF;

  -- Replace only this named maintenance job; leave all existing schedules intact.
  FOR v_job_id IN
    SELECT jobid
    FROM cron.job
    WHERE jobname = 'poyozz-cron-history-retention'
  LOOP
    PERFORM cron.unschedule(v_job_id);
  END LOOP;

  PERFORM cron.schedule(
    'poyozz-cron-history-retention',
    '17 3 * * *',
    $job$
      DELETE FROM cron.job_run_details
      WHERE end_time < clock_timestamp() - interval '7 days';
    $job$
  );
END;
$migration$;

-- Rollback (explicit operator action only):
-- SELECT cron.unschedule(jobid)
-- FROM cron.job
-- WHERE jobname = 'poyozz-cron-history-retention';
