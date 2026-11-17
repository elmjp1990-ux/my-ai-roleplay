-- Smoke-test the Encounter schedule SQL draft on disposable local Supabase only.
-- All changes are rolled back. This script must never be run against Hosted Supabase.

BEGIN;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.role = 'authenticated';
SELECT count(*) FROM public.get_encounter_scene_registry();
SELECT count(*) FROM public.get_encounter_city_weather();
SELECT count(*) FROM public.get_encounter_character_schedules(ARRAY[]::uuid[]);

RESET ROLE;

-- Seed one synthetic public character and an outdoor schedule in this disposable
-- transaction only. Disable FK/user triggers for these deliberately isolated IDs;
-- CHECK constraints remain active. The final ROLLBACK removes every row.
SET LOCAL session_replication_role = replica;
INSERT INTO public.characters (
  id, author_id, name, visibility, review_status, rights_confirmed, is_nsfw
) VALUES (
  '00000000-0000-4000-8000-000000000010'::uuid,
  '00000000-0000-4000-8000-000000000011'::uuid,
  'Encounter Rain Smoke', 'public', 'approved', true, false
);
INSERT INTO public.character_schedules (
  id, character_id, day_type, start_time, end_time, location_key, activity,
  priority, is_active, source_type, variant_key, variant_weight,
  encounter_greeting, is_outdoor,
  rain_fallback_location_key, rain_fallback_activity, rain_fallback_greeting
) VALUES (
  '00000000-0000-4000-8000-000000000012'::uuid,
  '00000000-0000-4000-8000-000000000010'::uuid,
  'weekday', '09:00', '17:00', 'park', '在公園散步',
  0, true, 'manual', 'primary', 100,
  '', true, 'cafe', '改到咖啡廳避雨',
  pg_catalog.repeat('雨勢漸大，你們改到附近咖啡廳坐下休息，窗外雨聲逐漸變得平穩。', 6)
);
SET LOCAL session_replication_role = origin;

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

  IF pg_catalog.strpos(
    pg_catalog.pg_get_functiondef(
      'public.schedule_encounter_worker(text,boolean)'::regprocedure
    ),
    '0 */6 * * *'
  ) = 0 THEN
    RAISE EXCEPTION 'weather scheduler must use a six-hour interval';
  END IF;

  IF pg_catalog.strpos(
    pg_catalog.pg_get_functiondef(
      'public.schedule_encounter_worker(text,boolean)'::regprocedure
    ),
    'encounter-weather-sync'
  ) = 0 THEN
    RAISE EXCEPTION 'weather scheduler endpoint is missing';
  END IF;

  v_scheduler_status := public.schedule_encounter_taiwan_calendar_sync(false);
  IF v_scheduler_status IS NULL THEN
    RAISE EXCEPTION 'Taiwan calendar scheduler disable check returned NULL';
  END IF;
END;
$encounter_schedule_smoke$;

DO $rainy_schedule_resolution_smoke$
DECLARE
  v_result record;
BEGIN
  UPDATE public.encounter_city_weather
  SET weather_text = '短暫陣雨',
      temperature_c = 25,
      is_raining = true,
      source = 'poyozz_fictional_seasonal',
      fetched_at = pg_catalog.now(),
      updated_at = pg_catalog.now()
  WHERE city_key = 'taipei';

  SELECT * INTO v_result
  FROM public.resolve_encounter_character_schedule(
    '00000000-0000-4000-8000-000000000010'::uuid,
    NULL,
    'cafe',
    '2026-11-17T10:00:00+08:00'::timestamptz
  );
  IF NOT FOUND
     OR v_result.location_key <> 'cafe'
     OR v_result.activity <> '改到咖啡廳避雨'
     OR v_result.is_outdoor IS NOT FALSE
     OR pg_catalog.char_length(v_result.encounter_greeting) NOT BETWEEN 150 AND 300 THEN
    RAISE EXCEPTION 'rainy outdoor schedule did not resolve to its indoor fallback';
  END IF;

  SELECT * INTO v_result
  FROM public.resolve_encounter_character_schedule(
    '00000000-0000-4000-8000-000000000010'::uuid,
    NULL,
    'park',
    '2026-11-17T10:00:00+08:00'::timestamptz
  );
  IF FOUND THEN
    RAISE EXCEPTION 'rainy outdoor schedule must not remain at its original outdoor location';
  END IF;

  UPDATE public.encounter_city_weather
  SET weather_text = '晴朗',
      is_raining = false,
      fetched_at = pg_catalog.now(),
      updated_at = pg_catalog.now()
  WHERE city_key = 'taipei';

  SELECT * INTO v_result
  FROM public.resolve_encounter_character_schedule(
    '00000000-0000-4000-8000-000000000010'::uuid,
    NULL,
    'park',
    '2026-11-17T10:00:00+08:00'::timestamptz
  );
  IF NOT FOUND
     OR v_result.location_key <> 'park'
     OR v_result.activity <> '在公園散步'
     OR v_result.is_outdoor IS NOT TRUE THEN
    RAISE EXCEPTION 'dry outdoor schedule did not resolve to its original location';
  END IF;
END;
$rainy_schedule_resolution_smoke$;

ROLLBACK;
