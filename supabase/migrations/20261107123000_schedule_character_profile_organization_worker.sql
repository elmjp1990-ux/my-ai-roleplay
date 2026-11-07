-- Optional pg_cron/pg_net scheduling for the Character AI Profile worker.
-- The worker is scheduled only when the operator has stored the project URL and
-- service-role key in Supabase Vault. No credentials are embedded in this file.

CREATE OR REPLACE FUNCTION public.schedule_character_profile_organization_worker()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_project_url text;
  v_service_key text;
  v_job_id bigint;
  v_headers jsonb;
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

  SELECT decrypted_secret INTO v_project_url
  FROM vault.decrypted_secrets
  WHERE name = 'poyozz_supabase_url'
  LIMIT 1;

  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets
  WHERE name = 'poyozz_service_role_key'
  LIMIT 1;

  IF COALESCE(v_project_url, '') !~ '^https://[a-zA-Z0-9-]+\.supabase\.co/?$'
     OR COALESCE(v_service_key, '') = '' THEN
    RETURN 'vault_secrets_missing';
  END IF;

  v_project_url := regexp_replace(v_project_url, '/+$', '');
  v_headers := jsonb_build_object(
    'Authorization', 'Bearer ' || v_service_key,
    'Content-Type', 'application/json'
  );
  v_command := format(
    'select net.http_post(url := %L, headers := %L::jsonb, body := %L::jsonb, timeout_milliseconds := 120000);',
    v_project_url || '/functions/v1/character-profile-organization-worker',
    v_headers::text,
    '{}'::jsonb::text
  );

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

REVOKE ALL ON FUNCTION public.schedule_character_profile_organization_worker()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.schedule_character_profile_organization_worker()
  TO service_role;

-- If the required Vault secrets and extensions already exist, install the
-- one-minute schedule now. Otherwise the service-role RPC can be called later
-- after adding the two Vault secrets; no schedule is created with missing keys.
DO $$
BEGIN
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  PERFORM public.schedule_character_profile_organization_worker();
END;
$$;
