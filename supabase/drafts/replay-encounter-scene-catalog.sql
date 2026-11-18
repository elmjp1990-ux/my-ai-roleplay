-- Disposable local-only replay for generalized Encounter scene metadata and legacy placeholders.
-- Latest PR #262 coverage: v6 hourly schedule hash, manual enqueue, dynamic marker cap, and fallback-only background metadata.
-- All synthetic rows and registry writes are rolled back. Never run against Hosted Supabase.

BEGIN;

-- A new scene key can be associated with the currently existing fallback image path;
-- this is metadata-only and does not add or upload an image asset.
INSERT INTO public.encounter_scene_backgrounds (
  location_key, display_name, asset_path, is_active, sort_order
) VALUES (
  'restaurant', 'Replay-only restaurant background metadata',
  './encounter-default-scene.webp', true, 999
);

SET LOCAL session_replication_role = replica;
INSERT INTO public.characters (
  id, author_id, name, intro, visibility, review_status, rights_confirmed, is_nsfw
) VALUES
  ('00000000-0000-4000-8000-000000000020'::uuid, '00000000-0000-4000-8000-000000000021'::uuid,
   'Legacy Placeholder Smoke', '現代都市角色', 'public', 'approved', true, false),
  ('00000000-0000-4000-8000-000000000022'::uuid, '00000000-0000-4000-8000-000000000023'::uuid,
   'Dynamic Scene Smoke A', '現代都市角色', 'public', 'approved', true, false),
  ('00000000-0000-4000-8000-000000000024'::uuid, '00000000-0000-4000-8000-000000000025'::uuid,
   'Dynamic Scene Smoke B', '現代都市角色', 'public', 'approved', true, false),
  ('00000000-0000-4000-8000-000000000029'::uuid, '00000000-0000-4000-8000-000000000030'::uuid,
   'Ancient Character Smoke', '古代架空王朝', 'public', 'approved', true, false),
  ('00000000-0000-4000-8000-000000000031'::uuid, '00000000-0000-4000-8000-000000000032'::uuid,
   'Public NSFW Smoke', '現代都市成人角色', 'public', 'approved', true, true);

INSERT INTO public.character_schedules (
  id, character_id, day_type, start_time, end_time, location_key, activity,
  priority, is_active, source_type, variant_key, variant_weight,
  encounter_greeting, is_outdoor
) VALUES
  ('00000000-0000-4000-8000-000000000026'::uuid,
   '00000000-0000-4000-8000-000000000020'::uuid,
   'any', '00:00', '23:59', 'airport', '舊版全天預設行程',
   0, true, 'legacy', 'primary', 100, '', false),
  ('00000000-0000-4000-8000-000000000027'::uuid,
   '00000000-0000-4000-8000-000000000022'::uuid,
   'any', '09:00', '17:00', 'restaurant', '在餐廳工作與接待客人',
   100, true, 'manual', 'primary', 100, '', false),
  ('00000000-0000-4000-8000-000000000028'::uuid,
   '00000000-0000-4000-8000-000000000024'::uuid,
   'any', '09:00', '17:00', 'restaurant', '在餐廳準備餐點與服務',
   100, true, 'manual', 'primary', 100, '', false),
  ('00000000-0000-4000-8000-000000000033'::uuid,
   '00000000-0000-4000-8000-000000000031'::uuid,
   'any', '09:00', '17:00', 'restaurant', '在餐廳工作與接待客人',
   100, true, 'manual', 'primary', 100, '', false);
-- Keep replica mode for the synthetic author IDs and their job rows; the whole test rolls back.

SET LOCAL ROLE service_role;
SET LOCAL request.jwt.claim.role = 'service_role';

DO $manual_enqueue$
DECLARE
  v_result jsonb;
  v_source jsonb;
BEGIN
  v_source := public.encounter_schedule_source_payload(
    '00000000-0000-4000-8000-000000000020'::uuid
  );
  IF v_source->>'schedule_schema_version' <> 'poyozz-encounter-schedule-v6-hourly-independent-options-2026-11-18' THEN
    RAISE EXCEPTION 'manual scene catalog migration must bump schedule source version';
  END IF;
  v_result := public.enqueue_encounter_schedule_generation_test_batch(2147483647);
  IF COALESCE((v_result->>'scanned_character_count')::integer, 0) < 5
     OR COALESCE((v_result->>'pending_character_count')::integer, 0)
        <> COALESCE((v_result->>'scanned_character_count')::integer, 0)
     OR (SELECT pg_catalog.count(*) FROM public.encounter_schedule_generation_jobs
         WHERE character_id = ANY(ARRAY[
           '00000000-0000-4000-8000-000000000020'::uuid,
           '00000000-0000-4000-8000-000000000022'::uuid,
           '00000000-0000-4000-8000-000000000024'::uuid,
           '00000000-0000-4000-8000-000000000029'::uuid,
           '00000000-0000-4000-8000-000000000031'::uuid
         ])
           AND status = 'pending') <> 5 THEN
    RAISE EXCEPTION 'manual Preview enqueue should queue every approved public role, including NSFW and historical-setting roles: %', v_result;
  END IF;
END;
$manual_enqueue$;

DO $legacy_placeholder_filter$
DECLARE
  v_result record;
BEGIN
  SELECT * INTO v_result
  FROM public.resolve_encounter_character_schedule(
    '00000000-0000-4000-8000-000000000020'::uuid,
    NULL,
    NULL,
    '2026-11-17T12:00:00+08:00'::timestamptz
  );
  IF FOUND THEN
    RAISE EXCEPTION 'legacy all-day placeholder must not resolve as a live Encounter schedule';
  END IF;
END;
$legacy_placeholder_filter$;

DO $dynamic_scene_publish$
DECLARE
  v_result jsonb;
  v_catalog record;
BEGIN
  v_result := public.publish_encounter_scene_metadata(
    jsonb_build_array(
      jsonb_build_object(
        'location_key', 'restaurant',
        'display_name', '城市餐廳',
        'icon', '🍽️',
        'heading', '讓香氣與交談交織的日常',
        'description', '開放式廚房傳來食材與鍋具的聲響，靠窗座位適合慢慢用餐，吧台則能看見廚師準備每一道料理。工作、聚餐與偶然相遇都能自然發生。',
        'event_label', '最新消息',
        'event_title', '本週季節菜單已更新',
        'event_description', '週末晚間將推出主廚限定套餐與小型料理分享。'
      ),
      jsonb_build_object(
        'location_key', 'live-house',
        'display_name', 'Live House／音樂酒吧',
        'icon', '🎸',
        'heading', '讓音樂填滿整個夜晚',
        'description', '舞台燈光、音箱震動與觀眾的歡呼交織成現場氛圍。演出前後的走廊與吧台，也可能發生比舞台更難忘的對話。',
        'event_label', '最新消息',
        'event_title', '本週演出時刻表已更新',
        'event_description', '週六晚間將舉辦新團專場演出。'
      )
    )
  );
  IF COALESCE((v_result->>'published_scene_count')::integer, 0) <> 2 THEN
    RAISE EXCEPTION 'shared dynamic scene and built-in Live House copy should both publish';
  END IF;

  SELECT * INTO v_catalog
  FROM public.get_encounter_scene_catalog()
  WHERE location_key = 'restaurant';
  IF NOT FOUND
     OR v_catalog.is_dynamic IS NOT TRUE
     OR v_catalog.character_count <> 3
     OR v_catalog.display_name <> '城市餐廳'
     OR v_catalog.event_title <> '本週季節菜單已更新' THEN
    RAISE EXCEPTION 'published dynamic scene metadata was not returned by the scene catalog';
  END IF;

  SELECT * INTO v_catalog
  FROM public.get_encounter_scene_catalog()
  WHERE location_key = 'live-house';
  IF NOT FOUND
     OR v_catalog.is_dynamic IS NOT FALSE
     OR v_catalog.display_name <> 'Live House／音樂酒吧'
     OR v_catalog.event_title <> '本週演出時刻表已更新' THEN
    RAISE EXCEPTION 'AI-updated built-in Live House scene copy was not returned by the scene catalog';
  END IF;
END;
$dynamic_scene_publish$;

-- Anonymous/minor callers must not receive NSFW-backed scene counts or schedules.
SET LOCAL ROLE anon;
SET LOCAL request.jwt.claim.role = 'anon';
DO $nsfw_viewer_gate$
DECLARE
  v_catalog record;
  v_schedule_count integer;
BEGIN
  SELECT * INTO v_catalog FROM public.get_encounter_scene_catalog() WHERE location_key = 'restaurant';
  IF NOT FOUND OR v_catalog.character_count <> 2 THEN
    RAISE EXCEPTION 'non-adult viewer must not see NSFW character scene counts';
  END IF;
  SELECT pg_catalog.count(*) INTO v_schedule_count
  FROM public.get_encounter_character_schedules(ARRAY['00000000-0000-4000-8000-000000000031'::uuid]);
  IF v_schedule_count <> 0 THEN
    RAISE EXCEPTION 'non-adult viewer must not receive NSFW character schedules';
  END IF;
END;
$nsfw_viewer_gate$;

SET LOCAL ROLE service_role;
SET LOCAL request.jwt.claim.role = 'service_role';
DO $internal_schedule_view$
DECLARE
  v_catalog record;
BEGIN
  SELECT * INTO v_catalog FROM public.get_encounter_scene_catalog() WHERE location_key = 'restaurant';
  IF NOT FOUND OR v_catalog.character_count <> 3 THEN
    RAISE EXCEPTION 'internal schedule generation must include NSFW-backed public scenes';
  END IF;
END;
$internal_schedule_view$;

ROLLBACK;
