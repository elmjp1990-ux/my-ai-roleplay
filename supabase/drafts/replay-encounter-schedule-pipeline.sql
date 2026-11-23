-- Smoke-test the Encounter schedule SQL draft on disposable local Supabase only.
-- All changes are rolled back. This script must never be run against Hosted Supabase.

BEGIN;

DO $priority_contract$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.claim_encounter_schedule_batch(integer,boolean,uuid)'::regprocedure
  ) INTO v_definition;
  IF pg_catalog.strpos(
    v_definition,
    'ORDER BY CASE j.status WHEN ''pending'' THEN 0 WHEN ''failed'' THEN 1 ELSE 2 END, j.queued_at, j.character_id'
  ) = 0 THEN
    RAISE EXCEPTION 'pending_schedule_job_priority_not_installed';
  END IF;
END;
$priority_contract$;

DO $strict_schedule_output_contract$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.publish_encounter_schedule_batch(uuid,uuid,jsonb)'::regprocedure
  ) INTO v_definition;
  IF pg_catalog.strpos(v_definition, 'NOT BETWEEN 2 AND 3') = 0
     OR pg_catalog.strpos(v_definition, 'v_multi_option_hours < 8') > 0
     OR pg_catalog.strpos(v_definition, 'NOT BETWEEN 1 AND 20') = 0
     OR pg_catalog.strpos(v_definition, 'NOT BETWEEN 8 AND 30') = 0
     OR pg_catalog.strpos(v_definition, 'rain_fallback_activity'' IS NULL') = 0
     OR pg_catalog.strpos(v_definition, 'schedule_hourly_option_unexpected_rain_fallback') > 0 THEN
    RAISE EXCEPTION 'natural_location_and_rain_fallback_contract_not_installed';
  END IF;
END;
$strict_schedule_output_contract$;

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
  id, character_id, day_type, start_time, end_time, location_key, location_description,
  activity, scene_description, priority, is_active, source_type, variant_key, variant_weight,
  encounter_greeting, is_outdoor
) VALUES
(
  '00000000-0000-4000-8000-000000000020'::uuid,
  '00000000-0000-4000-8000-000000000010'::uuid,
  'weekday', '06:00', '07:00', 'apartment', '私人公寓',
  '熟睡中', '他縮在被子裡熟睡，房間安靜得只剩空調聲。',
  50, true, 'ai', 'option_1', 80,
  pg_catalog.repeat('他仍安靜地睡著，房間裡只有窗外微弱的城市聲響。', 8), false
),
(
  '00000000-0000-4000-8000-000000000021'::uuid,
  '00000000-0000-4000-8000-000000000010'::uuid,
  'weekday', '06:00', '07:00', 'apartment', '私人公寓',
  '翻來覆去睡不著', '他在床上翻了幾次身，望著窗簾縫隙遲遲沒有睡意。',
  50, true, 'ai', 'option_2', 20,
  pg_catalog.repeat('他睜著眼望向窗邊，試著讓思緒慢慢平靜下來。', 8), false
),
(
  '00000000-0000-4000-8000-000000000022'::uuid,
  '00000000-0000-4000-8000-000000000010'::uuid,
  'weekday', '07:00', '08:00', 'apartment', '私人公寓',
  '繼續睡覺', '鬧鐘響過一次，他只是皺眉翻身，又沉沉睡去。',
  50, true, 'ai', 'option_1', 100,
  pg_catalog.repeat('他把鬧鐘按掉，重新縮回被子裡，暫時不想面對早晨。', 8), false
);

INSERT INTO public.character_schedules (
  id, character_id, day_type, start_time, end_time, location_key, activity,
  priority, is_active, source_type, variant_key, variant_weight,
  encounter_greeting, is_outdoor,
  rain_fallback_location_key, rain_fallback_activity, rain_fallback_greeting
) VALUES
(
  '00000000-0000-4000-8000-000000000012'::uuid,
  '00000000-0000-4000-8000-000000000010'::uuid,
  'weekday', '09:00', '12:00', 'park', '在公園散步',
  0, true, 'manual', 'primary', 100,
  '', true, 'convenience-store', '改到便利商店避雨',
  pg_catalog.repeat('雨勢漸大，你們改到附近便利商店坐下休息，窗外雨聲逐漸變得平穩。', 6)
),
(
  '00000000-0000-4000-8000-000000000013'::uuid,
  '00000000-0000-4000-8000-000000000010'::uuid,
  'weekday', '12:00', '14:00', 'park', '下一段公園行程',
  0, true, 'manual', 'primary', 100,
  '', true, 'convenience-store', '改到便利商店避雨',
  pg_catalog.repeat('下雨時改到便利商店等待雨勢變小。', 12)
);
INSERT INTO public.character_schedules (
  id, character_id, day_type, start_time, end_time, location_key, activity,
  priority, is_active, source_type, variant_key, variant_weight, special_event_key,
  encounter_greeting, is_outdoor
) VALUES (
  '00000000-0000-4000-8000-000000000015'::uuid,
  '00000000-0000-4000-8000-000000000010'::uuid,
  'any', '09:00', '17:00', 'shopping-street', '參加節日限定活動',
  0, true, 'manual', 'special', 100, 'lunar_new_year',
  pg_catalog.repeat('今天是假日限定活動日，你們在商店街安排了特別的展覽與交流，氣氛比平常更熱鬧。', 5),
  false
);
INSERT INTO public.character_schedules (
  id, character_id, day_type, start_time, end_time, location_key, activity,
  priority, is_active, source_type, variant_key, variant_weight, special_event_key,
  encounter_greeting, is_outdoor
) VALUES (
  '00000000-0000-4000-8000-000000000016'::uuid,
  '00000000-0000-4000-8000-000000000010'::uuid,
  'any', '09:00', '17:00', 'department-store', '一般假日活動',
  0, true, 'manual', 'special', 100, 'taiwan_public_holiday',
  pg_catalog.repeat('今天是政府公告的放假日，商場安排了特別活動，你們可以一起逛逛並享受假期。', 5),
  false
);
SET LOCAL session_replication_role = origin;

-- Hourly AI schedules intentionally omit greeting text. The resolver must
-- snapshot NULL source greetings as an empty string in its NOT NULL weather table.
INSERT INTO public.character_schedules (
  id, character_id, day_type, start_time, end_time, location_key, activity,
  priority, is_active, source_type, variant_key, variant_weight,
  encounter_greeting, is_outdoor
) VALUES (
  '00000000-0000-4000-8000-000000000023'::uuid,
  '00000000-0000-4000-8000-000000000010'::uuid,
  'weekday', '08:00', '09:00', 'apartment', '在家整理房間',
  70, true, 'manual', 'primary', 100, NULL, false
);

DO $schedule_source_version_smoke$
DECLARE
  v_payload jsonb;
BEGIN
  v_payload := public.encounter_schedule_source_payload(
    '00000000-0000-4000-8000-000000000010'::uuid
  );
  IF v_payload->>'schedule_schema_version' <> 'poyozz-encounter-schedule-v9-modern-setting-inference-2026-11-19' THEN
    RAISE EXCEPTION 'schedule source hash version was not updated for modern-setting inference';
  END IF;
END;
$schedule_source_version_smoke$;

SET LOCAL ROLE service_role;
SET LOCAL request.jwt.claim.role = 'service_role';

DO $hourly_schedule_option_smoke$
DECLARE
  v_first record;
  v_second record;
  v_roll integer;
  v_expected_key text;
BEGIN
  v_roll := pg_catalog.mod(
    pg_catalog.abs(pg_catalog.hashtext(
      '00000000-0000-4000-8000-000000000010'::uuid::text
      || '2026-11-17'
      || '06:00:00'
      || 'hourly-options-v1'
    )::bigint),
    100
  )::integer;
  v_expected_key := CASE WHEN v_roll < 80 THEN 'option_1' ELSE 'option_2' END;

  SELECT * INTO v_first
  FROM public.resolve_encounter_character_schedule(
    '00000000-0000-4000-8000-000000000010'::uuid,
    NULL,
    NULL,
    '2026-11-17T06:30:00+08:00'::timestamptz
  );
  SELECT * INTO v_second
  FROM public.resolve_encounter_character_schedule(
    '00000000-0000-4000-8000-000000000010'::uuid,
    NULL,
    NULL,
    '2026-11-17T06:30:00+08:00'::timestamptz
  );

  IF NOT FOUND
     OR v_first.variant_key <> v_expected_key
     OR v_second.schedule_id <> v_first.schedule_id
     OR v_second.variant_key <> v_first.variant_key
     OR v_first.variant_weight <> (CASE WHEN v_expected_key = 'option_1' THEN 80 ELSE 20 END) THEN
    RAISE EXCEPTION 'hourly option must be weighted and stable across same-day refreshes';
  END IF;

  SELECT * INTO v_first
  FROM public.resolve_encounter_character_schedule(
    '00000000-0000-4000-8000-000000000010'::uuid,
    NULL,
    NULL,
    '2026-11-17T07:30:00+08:00'::timestamptz
  );
  IF NOT FOUND OR v_first.variant_key <> 'option_1' OR v_first.variant_weight <> 100 THEN
    RAISE EXCEPTION 'a single-option hourly block must resolve as 100 percent';
  END IF;
END;
$hourly_schedule_option_smoke$;

DO $null_hourly_greeting_smoke$
DECLARE
  v_result record;
  v_snapshot_greeting text;
BEGIN
  SELECT * INTO v_result
  FROM public.resolve_encounter_character_schedule(
    '00000000-0000-4000-8000-000000000010'::uuid,
    NULL,
    NULL,
    '2026-11-17T08:30:00+08:00'::timestamptz
  );

  SELECT encounter_greeting INTO v_snapshot_greeting
  FROM public.encounter_schedule_weather_decisions
  WHERE schedule_id = '00000000-0000-4000-8000-000000000023'::uuid
    AND scheduled_start_at = '2026-11-17T08:00:00+08:00'::timestamptz;

  IF NOT FOUND
     OR v_result.schedule_id <> '00000000-0000-4000-8000-000000000023'::uuid
     OR v_result.encounter_greeting <> ''
     OR v_snapshot_greeting <> '' THEN
    RAISE EXCEPTION 'a schedule without an encounter greeting must resolve with an empty snapshot, not fail';
  END IF;
END;
$null_hourly_greeting_smoke$;

DO $unavailable_hourly_scene_option_smoke$
DECLARE
  v_result record;
  v_option_roll integer;
  v_option_weights integer[];
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.get_encounter_scene_catalog()
    WHERE location_key = 'hotel'
  ) THEN
    RAISE EXCEPTION 'synthetic replay expects hotel to be unavailable in the scene catalog';
  END IF;

  INSERT INTO public.character_schedules (
    id, character_id, day_type, start_time, end_time, location_key, location_description,
    activity, scene_description, priority, is_active, source_type, variant_key, variant_weight,
    encounter_greeting, is_outdoor
  ) VALUES
  (
    '00000000-0000-4000-8000-000000000030'::uuid,
    '00000000-0000-4000-8000-000000000010'::uuid,
    'weekday', '12:00', '13:00', 'hotel', '旅館',
    '外出用餐', '在旅館用餐。', 50, true, 'ai', 'option_1', 55,
    pg_catalog.repeat('他在旅館用餐，暫時不會出現在其他場景。', 9), false
  ),
  (
    '00000000-0000-4000-8000-000000000031'::uuid,
    '00000000-0000-4000-8000-000000000010'::uuid,
    'weekday', '12:00', '13:00', 'commercial', '商業大樓',
    '在辦公室處理工作', '他在辦公室整理工作資料。', 50, true, 'ai', 'option_2', 30,
    pg_catalog.repeat('他在辦公室處理工作，桌面上放著尚未整理完的文件。', 9), false
  ),
  (
    '00000000-0000-4000-8000-000000000032'::uuid,
    '00000000-0000-4000-8000-000000000010'::uuid,
    'weekday', '12:00', '13:00', 'apartment', '公寓',
    '在家簡單準備午餐', '他回到公寓準備簡單午餐。', 50, true, 'ai', 'option_3', 15,
    pg_catalog.repeat('他在家準備簡單午餐，廚房傳來輕微的餐具聲。', 9), false
  );

  SELECT array_agg(variant_weight ORDER BY variant_key)
    INTO v_option_weights
  FROM public.character_schedules
  WHERE character_id = '00000000-0000-4000-8000-000000000010'::uuid
    AND start_time = TIME '12:00'
    AND end_time = TIME '13:00'
    AND variant_key IN ('option_1', 'option_2', 'option_3');

  IF v_option_weights IS DISTINCT FROM ARRAY[55, 30, 15] THEN
    RAISE EXCEPTION 'unavailable scene must not alter the original option weights: %', v_option_weights;
  END IF;

  v_option_roll := pg_catalog.mod(
    pg_catalog.abs(pg_catalog.hashtext(
      '00000000-0000-4000-8000-000000000010'::uuid::text
      || '2026-11-17'
      || '12:00:00'
      || 'hourly-options-v1'
    )::bigint),
    100
  )::integer;

  IF v_option_roll >= 55 THEN
    RAISE EXCEPTION 'synthetic fixture no longer selects the unavailable hotel option: %', v_option_roll;
  END IF;

  -- This character also has a legacy manual primary row from 12:00–14:00
  -- for the separate weather-fallback smoke test. Manual schedules intentionally
  -- outrank AI schedules, so temporarily deactivate that overlapping fixture row
  -- to isolate the hourly weighted-option behavior under test.
  UPDATE public.character_schedules
  SET is_active = false
  WHERE id = '00000000-0000-4000-8000-000000000013'::uuid
    AND is_active IS TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'hourly unavailable-scene smoke could not isolate its legacy manual fixture';
  END IF;

  SELECT * INTO v_result
  FROM public.resolve_encounter_character_schedule(
    '00000000-0000-4000-8000-000000000010'::uuid,
    NULL,
    NULL,
    '2026-11-17T12:30:00+08:00'::timestamptz
  );

  IF FOUND THEN
    RAISE EXCEPTION 'when the original weighted choice is unavailable, the character must not appear or be rerolled; got % / %',
      v_result.location_key, v_result.variant_key;
  END IF;

  UPDATE public.character_schedules
  SET is_active = true
  WHERE id = '00000000-0000-4000-8000-000000000013'::uuid;
END;
$unavailable_hourly_scene_option_smoke$;

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

  -- This replay runs before the weekly-weather migration, so only the legacy
  -- weather worker exists at this point. The following migration adds the two new jobs.
  v_scheduler_status := public.schedule_encounter_worker('weather_sync', false);
  IF v_scheduler_status IS NULL THEN
    RAISE EXCEPTION 'legacy weather scheduler disable check returned NULL';
  END IF;

  IF pg_catalog.strpos(
    pg_catalog.pg_get_functiondef(
      'public.schedule_encounter_worker(text,boolean)'::regprocedure
    ),
    '0 0 * * 0'
  ) = 0 OR pg_catalog.strpos(
    pg_catalog.pg_get_functiondef('public.schedule_encounter_worker(text,boolean)'::regprocedure),
    '55 * * * *'
  ) = 0 THEN
    RAISE EXCEPTION 'weather scheduler must use weekly and minute-55 intervals';
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
  INSERT INTO public.encounter_city_weather (
    city_key, weather_text, temperature_c, is_raining, source, fetched_at, updated_at
  ) VALUES (
    'taipei', '短暫陣雨', 25, true, 'open_meteo_weekly_forecast',
    pg_catalog.now(), pg_catalog.now()
  )
  ON CONFLICT (city_key) DO UPDATE
  SET weather_text = EXCLUDED.weather_text,
      temperature_c = EXCLUDED.temperature_c,
      is_raining = EXCLUDED.is_raining,
      source = EXCLUDED.source,
      fetched_at = EXCLUDED.fetched_at,
      updated_at = EXCLUDED.updated_at;

  SELECT * INTO v_result
  FROM public.resolve_encounter_character_schedule(
    '00000000-0000-4000-8000-000000000010'::uuid,
    NULL,
    'convenience-store',
    '2026-11-17T10:00:00+08:00'::timestamptz
  );
  IF NOT FOUND
     OR v_result.location_key <> 'convenience-store'
     OR v_result.activity <> '改到便利商店避雨'
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

  -- Rain stops mid-slot: the original slot remains in the convenience store until 12:00.
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
    'convenience-store',
    '2026-11-17T11:00:00+08:00'::timestamptz
  );
  IF NOT FOUND
     OR v_result.schedule_id <> '00000000-0000-4000-8000-000000000012'::uuid
     OR v_result.location_key <> 'convenience-store'
     OR v_result.activity <> '改到便利商店避雨'
     OR v_result.is_outdoor IS NOT FALSE THEN
    RAISE EXCEPTION 'rain stop must not move an active slot back to its original outdoor location';
  END IF;

  -- A new schedule slot makes a fresh weather decision; the dry next slot
  -- can return to the original outdoor location without changing the old slot.
  SELECT * INTO v_result
  FROM public.resolve_encounter_character_schedule(
    '00000000-0000-4000-8000-000000000010'::uuid,
    NULL,
    'park',
    '2026-11-17T12:00:00+08:00'::timestamptz
  );
  IF NOT FOUND
     OR v_result.schedule_id <> '00000000-0000-4000-8000-000000000013'::uuid
     OR v_result.location_key <> 'park'
     OR v_result.activity <> '下一段公園行程'
     OR v_result.is_outdoor IS NOT TRUE THEN
    RAISE EXCEPTION 'the next schedule must make a fresh weather decision';
  END IF;
END;
$rainy_schedule_resolution_smoke$;

DO $special_event_schedule_smoke$
DECLARE
  v_result record;
BEGIN
  INSERT INTO public.taiwan_calendar_days (calendar_date, day_type, holiday_name, source)
  VALUES ('2026-11-17'::date, 'holiday', '農曆春節', 'disposable_smoke_test')
  ON CONFLICT (calendar_date) DO UPDATE
  SET day_type = EXCLUDED.day_type,
      holiday_name = EXCLUDED.holiday_name,
      source = EXCLUDED.source,
      updated_at = pg_catalog.now();

  INSERT INTO public.taiwan_calendar_days (calendar_date, day_type, holiday_name, source)
  VALUES ('2026-11-19'::date, 'holiday', '國定假日', 'disposable_smoke_test')
  ON CONFLICT (calendar_date) DO UPDATE
  SET day_type = EXCLUDED.day_type,
      holiday_name = EXCLUDED.holiday_name,
      source = EXCLUDED.source,
      updated_at = pg_catalog.now();

  IF public.resolve_encounter_special_event_key('2026-11-17'::date) <> 'lunar_new_year'
     OR public.resolve_encounter_special_event_key('2026-11-19'::date) <> 'taiwan_public_holiday'
     OR public.resolve_encounter_special_event_key('2026-02-14'::date) <> 'valentines_day'
     OR public.resolve_encounter_special_event_key('2026-12-25'::date) <> 'christmas'
     OR public.resolve_encounter_special_event_key('2026-11-18'::date) IS NOT NULL THEN
    RAISE EXCEPTION 'special event date resolver returned an unexpected key';
  END IF;

  SELECT * INTO v_result
  FROM public.resolve_encounter_character_schedule(
    '00000000-0000-4000-8000-000000000010'::uuid,
    NULL,
    'shopping-street',
    '2026-11-17T10:00:00+08:00'::timestamptz
  );
  IF NOT FOUND
     OR v_result.location_key <> 'shopping-street'
     OR v_result.activity <> '參加節日限定活動'
     OR v_result.variant_key <> 'special' THEN
    RAISE EXCEPTION 'Lunar New Year specific schedule was not selected';
  END IF;

  SELECT * INTO v_result
  FROM public.resolve_encounter_character_schedule(
    '00000000-0000-4000-8000-000000000010'::uuid,
    NULL,
    'department-store',
    '2026-11-17T10:00:00+08:00'::timestamptz
  );
  IF NOT FOUND
     OR v_result.activity <> '一般假日活動'
     OR v_result.variant_key <> 'special' THEN
    RAISE EXCEPTION 'generic public holiday schedule should be a fallback on Lunar New Year';
  END IF;

  SELECT * INTO v_result
  FROM public.resolve_encounter_character_schedule(
    '00000000-0000-4000-8000-000000000010'::uuid,
    NULL,
    'department-store',
    '2026-11-19T10:00:00+08:00'::timestamptz
  );
  IF NOT FOUND
     OR v_result.activity <> '一般假日活動' THEN
    RAISE EXCEPTION 'generic public holiday schedule was not selected for a named holiday';
  END IF;

  SELECT * INTO v_result
  FROM public.resolve_encounter_character_schedule(
    '00000000-0000-4000-8000-000000000010'::uuid,
    NULL,
    'shopping-street',
    '2026-11-18T10:00:00+08:00'::timestamptz
  );
  IF FOUND THEN
    RAISE EXCEPTION 'special holiday schedule must not leak into an ordinary day';
  END IF;
END;
$special_event_schedule_smoke$;

ROLLBACK;
