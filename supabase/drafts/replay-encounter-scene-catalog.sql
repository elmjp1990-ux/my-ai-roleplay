-- Disposable local-only replay for generalized Encounter scene metadata and legacy placeholders.
-- All synthetic rows and registry writes are rolled back. Never run against Hosted Supabase.

BEGIN;

SET LOCAL session_replication_role = replica;
INSERT INTO public.characters (
  id, author_id, name, visibility, review_status, rights_confirmed, is_nsfw
) VALUES
  ('00000000-0000-4000-8000-000000000020'::uuid, '00000000-0000-4000-8000-000000000021'::uuid,
   'Legacy Placeholder Smoke', 'public', 'approved', true, false),
  ('00000000-0000-4000-8000-000000000022'::uuid, '00000000-0000-4000-8000-000000000023'::uuid,
   'Dynamic Scene Smoke A', 'public', 'approved', true, false),
  ('00000000-0000-4000-8000-000000000024'::uuid, '00000000-0000-4000-8000-000000000025'::uuid,
   'Dynamic Scene Smoke B', 'public', 'approved', true, false);

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
   100, true, 'manual', 'primary', 100, '', false);
SET LOCAL session_replication_role = origin;

SET LOCAL ROLE service_role;
SET LOCAL request.jwt.claim.role = 'service_role';

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
    jsonb_build_array(jsonb_build_object(
      'location_key', 'restaurant',
      'display_name', '城市餐廳',
      'icon', '🍽️',
      'heading', '讓香氣與交談交織的日常',
      'description', '開放式廚房傳來食材與鍋具的聲響，靠窗座位適合慢慢用餐，吧台則能看見廚師準備每一道料理。工作、聚餐與偶然相遇都能自然發生。',
      'event_label', '最新消息',
      'event_title', '本週季節菜單已更新',
      'event_description', '週末晚間將推出主廚限定套餐與小型料理分享。'
    ))
  );
  IF COALESCE((v_result->>'published_scene_count')::integer, 0) <> 1 THEN
    RAISE EXCEPTION 'shared dynamic scene should publish after two distinct characters are scheduled there';
  END IF;

  SELECT * INTO v_catalog
  FROM public.get_encounter_scene_catalog()
  WHERE location_key = 'restaurant';
  IF NOT FOUND
     OR v_catalog.is_dynamic IS NOT TRUE
     OR v_catalog.character_count <> 2
     OR v_catalog.display_name <> '城市餐廳'
     OR v_catalog.event_title <> '本週季節菜單已更新' THEN
    RAISE EXCEPTION 'published dynamic scene metadata was not returned by the scene catalog';
  END IF;
END;
$dynamic_scene_publish$;

ROLLBACK;
