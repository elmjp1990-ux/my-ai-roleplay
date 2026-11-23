-- POYOZZ shared Taipei weather: weekly 7-day hourly forecast sync + hourly state refresh at :55.
BEGIN;

CREATE TABLE IF NOT EXISTS public.encounter_city_weather_forecast_hourly (
  city_key text NOT NULL CHECK (city_key = 'taipei'),
  forecast_at timestamptz NOT NULL,
  weather_code integer NOT NULL,
  weather_text text NOT NULL,
  temperature_c numeric(4,1) NOT NULL,
  precipitation_probability integer NOT NULL CHECK (precipitation_probability BETWEEN 0 AND 100),
  fetched_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  PRIMARY KEY (city_key, forecast_at)
);
ALTER TABLE public.encounter_city_weather_forecast_hourly ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.encounter_city_weather_forecast_hourly FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_city_weather_forecast_hourly TO service_role;

ALTER TABLE public.encounter_city_weather
  ADD COLUMN IF NOT EXISTS precipitation_probability integer CHECK (precipitation_probability BETWEEN 0 AND 100),
  ADD COLUMN IF NOT EXISTS forecast_for timestamptz,
  ADD COLUMN IF NOT EXISTS forecast_synced_at timestamptz;

CREATE OR REPLACE FUNCTION public.get_encounter_city_weather_v2()
RETURNS TABLE (
  weather_text text,
  temperature_c numeric,
  is_raining boolean,
  precipitation_1h_mm numeric,
  observed_at timestamptz,
  source text,
  precipitation_probability integer,
  forecast_for timestamptz,
  forecast_synced_at timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT
    COALESCE(w.weather_text, '多雲'),
    COALESCE(w.temperature_c, 24::numeric),
    COALESCE(w.is_raining, false),
    w.precipitation_1h_mm,
    COALESCE(w.observed_at, w.fetched_at),
    COALESCE(w.source, 'poyozz_fallback'),
    w.precipitation_probability,
    w.forecast_for,
    w.forecast_synced_at
  FROM public.encounter_city_weather w
  WHERE w.city_key='taipei'
  UNION ALL
  SELECT '多雲',24::numeric,false,NULL::numeric,pg_catalog.now(),'poyozz_fallback',NULL,NULL,NULL
  WHERE NOT EXISTS (SELECT 1 FROM public.encounter_city_weather WHERE city_key='taipei')
  LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.get_encounter_city_weather_v2() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_encounter_city_weather_v2() TO anon, authenticated, service_role;

DO $scheduler$
DECLARE
  v_def text;
  v_old text := $old$    WHEN 'weather_sync' THEN
      v_job_name := 'poyozz-encounter-weather-sync';
      v_cron_schedule := '0 */6 * * *';
      v_endpoint := 'encounter-weather-sync';
      v_timeout := 30000;$old$;
  v_new text := $new$    WHEN 'weather_sync' THEN
      v_job_name := 'poyozz-encounter-weather-weekly-sync';
      v_cron_schedule := '0 0 * * 0';
      v_endpoint := 'encounter-weather-sync';
      v_timeout := 60000;
      v_task := 'weekly_sync';
    WHEN 'weather_hourly_update' THEN
      v_job_name := 'poyozz-encounter-weather-hourly-update';
      v_cron_schedule := '55 * * * *';
      v_endpoint := 'encounter-weather-sync';
      v_timeout := 30000;
      v_task := 'hourly_update';$new$;
  v_old_body text := $oldbody$        body := '{"mode":"scheduled"}'::jsonb,
        timeout_milliseconds := %s$oldbody$;
  v_new_body text := $newbody$        body := jsonb_build_object('mode', 'scheduled', 'task', '%s'),
        timeout_milliseconds := %s$newbody$;
  v_old_format text := $oldformat$    v_endpoint,
    v_timeout
  );$oldformat$;
  v_new_format text := $newformat$    v_endpoint,
    v_task,
    v_timeout
  );$newformat$;
BEGIN
  SELECT pg_catalog.pg_get_functiondef('public.schedule_encounter_worker(text,boolean)'::regprocedure) INTO v_def;
  IF pg_catalog.strpos(v_def,'  v_timeout integer;')=0
     OR pg_catalog.strpos(v_def,v_old)=0
     OR pg_catalog.strpos(v_def,v_old_body)=0
     OR pg_catalog.strpos(v_def,v_old_format)=0 THEN
    RAISE EXCEPTION 'weather_cron_function_anchor_missing';
  END IF;
  v_def := pg_catalog.replace(v_def,'  v_timeout integer;','  v_timeout integer;' || pg_catalog.chr(10) || '  v_task text;');
  v_def := pg_catalog.replace(v_def,v_old,v_new);
  v_def := pg_catalog.replace(v_def,v_old_body,v_new_body);
  v_def := pg_catalog.replace(v_def,v_old_format,v_new_format);
  EXECUTE v_def;
END;
$scheduler$;

-- Disable the previous six-hour simulated-weather Cron; new jobs are explicitly enabled later.
DO $legacy_cron$
DECLARE v_job_id bigint;
BEGIN
  IF pg_catalog.to_regclass('cron.job') IS NOT NULL
     AND pg_catalog.to_regprocedure('cron.unschedule(bigint)') IS NOT NULL THEN
    FOR v_job_id IN SELECT jobid FROM cron.job WHERE jobname='poyozz-encounter-weather-sync'
    LOOP PERFORM cron.unschedule(v_job_id); END LOOP;
  END IF;
END;
$legacy_cron$;

DROP FUNCTION IF EXISTS public.schedule_encounter_weather_sync(boolean);

CREATE OR REPLACE FUNCTION public.schedule_encounter_weather_weekly_sync(p_enabled boolean DEFAULT false)
RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $ SELECT public.schedule_encounter_worker('weather_sync',p_enabled); $;
REVOKE ALL ON FUNCTION public.schedule_encounter_weather_weekly_sync(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.schedule_encounter_weather_weekly_sync(boolean) TO service_role;

CREATE OR REPLACE FUNCTION public.schedule_encounter_weather_hourly_update(p_enabled boolean DEFAULT false)
RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $$ SELECT public.schedule_encounter_worker('weather_hourly_update',p_enabled); $$;
REVOKE ALL ON FUNCTION public.schedule_encounter_weather_hourly_update(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.schedule_encounter_weather_hourly_update(boolean) TO service_role;

COMMENT ON TABLE public.encounter_city_weather_forecast_hourly IS
  'Shared Taipei hourly forecast cache, synced once weekly; only weather state, temperature and precipitation probability are retained.';
COMMENT ON TABLE public.encounter_city_weather IS
  'Shared Taipei current-hour weather state selected from weekly forecast cache by hourly :55 worker.';
COMMIT;
