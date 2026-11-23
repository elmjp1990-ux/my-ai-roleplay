-- Verify scheduled weather requests against the service-role key stored in Vault.
-- The Edge Function's injected service key can differ from the rotated legacy API key.
CREATE OR REPLACE FUNCTION public.verify_encounter_weather_cron_key(p_candidate text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM vault.decrypted_secrets
    WHERE name = 'poyozz_service_role_key'
      AND decrypted_secret = p_candidate
  );
$$;

REVOKE ALL ON FUNCTION public.verify_encounter_weather_cron_key(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.verify_encounter_weather_cron_key(text) TO service_role;

COMMENT ON FUNCTION public.verify_encounter_weather_cron_key(text) IS
  'Internal service-role-only comparison for the scheduled Taipei weather Edge Function.';
