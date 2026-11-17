CREATE OR REPLACE FUNCTION public.schedule_encounter_evaluation_worker(
  p_enabled boolean DEFAULT false
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_project_url text;
  v_service_key text;
  v_job_id bigint;
  v_command text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  IF to_regclass('cron.job') IS NULL
     OR to_regclass('vault.decrypted_secrets') IS NULL
     OR to_regprocedure('cron.schedule(text,text,text)') IS NULL
     OR to_regprocedure('cron.unschedule(bigint)') IS NULL
     OR to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') IS NULL THEN
    RETURN 'scheduler_extensions_missing';
  END IF;

  IF p_enabled IS NOT TRUE THEN
    FOR v_job_id IN
      SELECT jobid FROM cron.job
      WHERE jobname = 'poyozz-encounter-evaluation-worker'
    LOOP
      PERFORM cron.unschedule(v_job_id);
    END LOOP;
    RETURN 'disabled';
  END IF;

  SELECT decrypted_secret INTO v_project_url
  FROM vault.decrypted_secrets
  WHERE name = 'poyozz_supabase_url'
  LIMIT 1;

  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets
  WHERE name = 'poyozz_service_role_key'
  LIMIT 1;

  IF COALESCE(v_project_url, '') !~ '^https://[a-zA-Z0-9-]+[.]supabase[.]co/?$'
     OR COALESCE(v_service_key, '') = '' THEN
    RETURN 'vault_secrets_missing';
  END IF;

  -- The persistent cron command contains secret names only. Values are resolved
  -- from Vault at execution time and are never written into cron.job.command.
  v_command := $command$
    DO $dispatch$
    BEGIN
      -- First move every eligible expired Encounter into the evaluation queue.
      -- This is the missing bridge between scene expiry and the AI worker.
      PERFORM public.enqueue_due_encounter_evaluations(50);

      IF EXISTS (
        SELECT 1
        FROM public.encounter_session_evaluation_jobs AS job
        JOIN public.encounter_session_lifecycle AS lifecycle
          ON lifecycle.session_id = job.session_id
        WHERE lifecycle.status = 'ready_to_settle'
          AND lifecycle.scheduled_end_at <= clock_timestamp()
          AND job.attempt_count < 5
          AND (
            job.status = 'pending'
            OR (job.status = 'failed'
                AND job.updated_at <= clock_timestamp() - interval '5 minutes')
            OR (job.status = 'processing'
                AND job.claimed_at < clock_timestamp() - interval '10 minutes')
          )
      ) THEN
        PERFORM net.http_post(
          url := regexp_replace(
            (SELECT decrypted_secret FROM vault.decrypted_secrets
             WHERE name = 'poyozz_supabase_url' LIMIT 1),
            '/+$', ''
          ) || '/functions/v1/encounter-evaluation-worker',
          headers := jsonb_build_object(
            'Authorization', 'Bearer ' || (
              SELECT decrypted_secret FROM vault.decrypted_secrets
              WHERE name = 'poyozz_service_role_key' LIMIT 1
            ),
            'Content-Type', 'application/json'
          ),
          body := '{"limit":1}'::jsonb,
          timeout_milliseconds := 120000
        );
      END IF;
    END;
    $dispatch$;
  $command$;

  FOR v_job_id IN
    SELECT jobid FROM cron.job
    WHERE jobname = 'poyozz-encounter-evaluation-worker'
  LOOP
    PERFORM cron.unschedule(v_job_id);
  END LOOP;

  PERFORM cron.schedule(
    'poyozz-encounter-evaluation-worker',
    '* * * * *',
    v_command
  );

  RETURN 'scheduled';
END;
$$;

REVOKE ALL ON FUNCTION public.schedule_encounter_evaluation_worker(boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.schedule_encounter_evaluation_worker(boolean)
  TO service_role;

COMMENT ON FUNCTION public.schedule_encounter_evaluation_worker(boolean) IS
  'Opt-in, service-role-only scheduler for the trusted Encounter affinity evaluator. Disabled by default; the cron command reads credentials from Vault at runtime.';
