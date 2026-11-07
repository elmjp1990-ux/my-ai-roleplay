-- Optional pg_cron/pg_net scheduling for the Character AI Profile worker.
-- The cron command stores only SQL that reads the current URL/key from Vault at
-- execution time. No decrypted credential is persisted in cron.job.command.
-- Creating this migration does NOT enable the schedule; an operator must call
-- the service-role RPC explicitly after the Worker and Vault secrets are ready.

DROP FUNCTION IF EXISTS public.schedule_character_profile_organization_worker();

CREATE OR REPLACE FUNCTION public.schedule_character_profile_organization_worker(
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
  IF auth.role() <> 'service_role' THEN
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
      WHERE jobname = 'poyozz-character-profile-organization-worker'
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

  IF COALESCE(v_project_url, '') !~ '^https://[a-zA-Z0-9-]+\\.supabase\\.co/?$'
     OR COALESCE(v_service_key, '') = '' THEN
    RETURN 'vault_secrets_missing';
  END IF;

  -- Resolve both secrets at execution time. The persistent cron command contains
  -- secret names only; it never contains the decrypted URL or service-role key.
  v_command := $command$
    SELECT net.http_post(
      url := regexp_replace(
        (SELECT decrypted_secret FROM vault.decrypted_secrets
         WHERE name = 'poyozz_supabase_url' LIMIT 1),
        '/+$', ''
      ) || '/functions/v1/character-profile-organization-worker',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || (
          SELECT decrypted_secret FROM vault.decrypted_secrets
          WHERE name = 'poyozz_service_role_key' LIMIT 1
        ),
        'Content-Type', 'application/json'
      ),
      body := '{}'::jsonb,
      timeout_milliseconds := 120000
    );
  $command$;

  FOR v_job_id IN
    SELECT jobid FROM cron.job
    WHERE jobname = 'poyozz-character-profile-organization-worker'
  LOOP
    PERFORM cron.unschedule(v_job_id);
  END LOOP;

  PERFORM cron.schedule(
    'poyozz-character-profile-organization-worker',
    '* * * * *',
    v_command
  );

  RETURN 'scheduled';
END;
$$;

REVOKE ALL ON FUNCTION public.schedule_character_profile_organization_worker(boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.schedule_character_profile_organization_worker(boolean)
  TO service_role;

-- Intentionally no migration-time DO block: schedule activation is a separate,
-- explicit operator action after deployment and secret verification.
