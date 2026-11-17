-- Smoke-test the Encounter schedule SQL draft on disposable local Supabase only.
-- All changes are rolled back. This script must never be run against Hosted Supabase.

BEGIN;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.role = 'authenticated';
SELECT count(*) FROM public.get_encounter_scene_registry();
SELECT count(*) FROM public.get_encounter_city_weather();
SELECT count(*) FROM public.get_encounter_character_schedules(ARRAY[]::uuid[]);

RESET ROLE;
SET LOCAL ROLE service_role;
SET LOCAL request.jwt.claim.role = 'service_role';

DO $weather_fallback_smoke$
DECLARE
  v_weather record;
BEGIN
  SELECT * INTO v_weather FROM public.get_encounter_city_weather();
  IF NOT FOUND
     OR v_weather.weather_text <> '多雲'
     OR v_weather.temperature_c <> 24
     OR v_weather.is_raining IS NOT FALSE
     OR v_weather.weather_source <> 'poyozz_fallback' THEN
    RAISE EXCEPTION 'empty weather cache must return the lightweight Taipei fallback';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.encounter_scene_backgrounds
    WHERE location_key = '*'
      AND asset_path = './encounter-default-scene.webp'
      AND is_active IS TRUE
  ) THEN
    RAISE EXCEPTION 'default encounter scene background is missing';
  END IF;
END;
$weather_fallback_smoke$;

SELECT count(*)
FROM public.resolve_encounter_character_schedule(
  '00000000-0000-4000-8000-000000000001'::uuid,
  NULL,
  NULL,
  '2026-11-17T10:00:00+08:00'::timestamptz
);

DO $encounter_schedule_smoke$
DECLARE
  v_result jsonb;
  v_scheduler_status text;
BEGIN
  v_result := public.claim_encounter_schedule_batch(10, false, NULL);
  IF jsonb_typeof(v_result) <> 'object' THEN
    RAISE EXCEPTION 'claim_encounter_schedule_batch did not return an object';
  END IF;

  IF v_result->>'status' = 'claimed' THEN
    PERFORM public.fail_encounter_schedule_batch(
      (v_result->>'batch_id')::uuid,
      (v_result->>'lease_token')::uuid,
      'local_smoke_cleanup',
      false,
      false
    );
  END IF;

  IF public.fail_encounter_schedule_batch(
    '00000000-0000-4000-8000-000000000002'::uuid,
    '00000000-0000-4000-8000-000000000003'::uuid,
    'expected_missing_batch',
    false,
    false
  ) IS TRUE THEN
    RAISE EXCEPTION 'missing batch unexpectedly succeeded';
  END IF;

  BEGIN
    PERFORM public.publish_encounter_schedule_batch(
      '00000000-0000-4000-8000-000000000002'::uuid,
      '00000000-0000-4000-8000-000000000003'::uuid,
      '[]'::jsonb
    );
    RAISE EXCEPTION 'publish unexpectedly accepted a missing batch';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM <> 'schedule_batch_lease_not_found' THEN
        RAISE;
      END IF;
  END;

  v_scheduler_status := public.schedule_encounter_schedule_organizer(false);
  IF v_scheduler_status IS NULL THEN
    RAISE EXCEPTION 'scheduler disable check returned NULL';
  END IF;

  v_scheduler_status := public.schedule_encounter_weather_sync(false);
  IF v_scheduler_status IS NULL THEN
    RAISE EXCEPTION 'weather scheduler disable check returned NULL';
  END IF;

  IF pg_catalog.position(
    '0 */6 * * *' IN pg_catalog.pg_get_functiondef(
      'public.schedule_encounter_worker(text,boolean)'::regprocedure
    )
  ) = 0 THEN
    RAISE EXCEPTION 'weather scheduler must use a six-hour interval';
  END IF;

  IF pg_catalog.position(
    'encounter-weather-sync' IN pg_catalog.pg_get_functiondef(
      'public.schedule_encounter_worker(text,boolean)'::regprocedure
    )
  ) = 0 THEN
    RAISE EXCEPTION 'weather scheduler endpoint is missing';
  END IF;

  v_scheduler_status := public.schedule_encounter_taiwan_calendar_sync(false);
  IF v_scheduler_status IS NULL THEN
    RAISE EXCEPTION 'Taiwan calendar scheduler disable check returned NULL';
  END IF;
END;
$encounter_schedule_smoke$;

ROLLBACK;
