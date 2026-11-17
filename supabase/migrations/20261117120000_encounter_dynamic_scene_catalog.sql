-- Generalize AI-generated encounter scenes while preserving server-owned map geometry.
-- This migration is source-only until explicitly applied to Hosted Supabase.

ALTER TABLE public.encounter_scene_registry
  DROP CONSTRAINT IF EXISTS encounter_scene_registry_dynamic_key_check;

DO $$
DECLARE
  v_constraint record;
BEGIN
  FOR v_constraint IN
    SELECT conname
    FROM pg_catalog.pg_constraint
    WHERE conrelid = 'public.encounter_scene_registry'::regclass
      AND contype = 'c'
      AND pg_catalog.pg_get_constraintdef(oid) ILIKE '%is_dynamic%'
      AND pg_catalog.pg_get_constraintdef(oid) ILIKE '%shopping-street%'
  LOOP
    EXECUTE pg_catalog.format(
      'ALTER TABLE public.encounter_scene_registry DROP CONSTRAINT %I',
      v_constraint.conname
    );
  END LOOP;
END;
$$;

ALTER TABLE public.encounter_scene_registry
  ADD CONSTRAINT encounter_scene_registry_dynamic_key_check
  CHECK (
    is_dynamic IS FALSE OR location_key IN (
      'shopping-street', 'night-market', 'restaurant', 'university', 'hospital',
      'gym', 'cinema', 'museum', 'hotel', 'train-station', 'library', 'theater',
      'art-gallery', 'community-center', 'music-studio', 'bakery', 'coworking-space'
    )
  );

-- Expand allowed background location keys only; no image assets are added by this migration.
DO $
DECLARE
  v_constraint record;
BEGIN
  FOR v_constraint IN
    SELECT conname
    FROM pg_catalog.pg_constraint
    WHERE conrelid = 'public.encounter_scene_backgrounds'::regclass
      AND contype = 'c'
      AND pg_catalog.pg_get_constraintdef(oid) ILIKE '%location_key%'
      AND pg_catalog.pg_get_constraintdef(oid) ILIKE '%shopping-street%'
  LOOP
    EXECUTE pg_catalog.format(
      'ALTER TABLE public.encounter_scene_backgrounds DROP CONSTRAINT %I',
      v_constraint.conname
    );
  END LOOP;
END;
$;

ALTER TABLE public.encounter_scene_backgrounds
  ADD CONSTRAINT encounter_scene_backgrounds_location_key_check
  CHECK (
    location_key = '*' OR location_key IN (
      'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
      'department-store', 'bookstore', 'cafe', 'park', 'shopping-street',
      'night-market', 'restaurant', 'university', 'hospital', 'gym', 'cinema',
      'museum', 'hotel', 'train-station', 'library', 'theater', 'art-gallery',
      'community-center', 'music-studio', 'bakery', 'coworking-space'
    )
  );

-- Seed metadata rows for the existing static map locations. Existing user data is preserved.
INSERT INTO public.encounter_scene_registry (
  location_key, display_name, icon, marker_x, marker_y, heading, description,
  event_label, event_title, event_description, is_dynamic,
  minimum_character_count, display_order, is_active
) VALUES
  ('airport', '機場', '✈️', 220, 140, '城市的起點與交會處',
   '航班資訊在大廳螢幕上流動，旅人拖著行李匆匆經過。候機座位、接機大廳與深夜航班，總有新的相遇可能。',
   '最新消息', '抵達大廳的日常', '大廳服務與旅客動線資訊已更新。', false, 1, 1, true),
  ('commercial', '商業大樓', '🏢', 1305, 94, '玻璃帷幕下的繁忙日常',
   '電梯穿梭於不同樓層，會議室、辦公座位與窗邊休息區構成城市工作的節奏。白天忙碌，傍晚後則逐漸安靜。',
   '最新消息', '辦公樓層公告', '公共空間與會議區使用資訊已更新。', false, 1, 2, true),
  ('night-bar', '夜間酒吧', '🍸', 632, 294, '霓虹燈下的微醺夜色',
   '低亮度燈光映著吧台酒杯，音樂與交談聲交錯。角落座位保留一點私密感，適合卸下白天的面具。',
   '最新消息', '今晚的音樂時段', '週末夜間將有不同主題的音樂安排。', false, 1, 3, true),
  ('live-house', 'Live House／音樂酒吧', '🎸', 868, 416, '讓音樂填滿整個夜晚',
   '舞台燈光、音箱震動與觀眾的歡呼交織成現場氛圍。演出前後的走廊與吧台，也可能發生比舞台更難忘的對話。',
   '最新消息', '本週演出時刻表已更新', '週六晚間將舉辦新團專場演出。', false, 1, 4, true),
  ('apartment', '308 公寓', '🏠', 666, 440, '308 公寓的日常與秘密',
   '熟悉的電梯聲、走廊燈光與各自緊閉的房門，讓這裡既有生活感，也保留鄰居之間尚未說出口的故事。',
   '最新消息', '公共空間公告', '住戶交誼區與訪客動線資訊已更新。', false, 1, 5, true),
  ('department-store', '百貨公司', '🛍️', 1020, 300, '從精品櫥窗到美食樓層',
   '明亮的中庭連接各式品牌櫃位、服飾樓層與餐飲空間。人潮來去，購物、約會與臨時起意的行程都能在這裡展開。',
   '最新消息', '中庭活動資訊', '本週末中庭將有季節主題展。', false, 1, 6, true),
  ('bookstore', '書店', '📚', 480, 733, '在書頁之間慢下腳步',
   '木質書架與紙張氣味讓時間放慢。新書展示區、靠窗閱讀座位與安靜的書架轉角，各自藏著不同的相遇方式。',
   '最新消息', '本週新書已上架', '週末午後將安排閱讀交流活動。', false, 1, 7, true),
  ('cafe', '咖啡廳', '☕', 645, 624, '在城市裡，找個地方歇歇腳',
   '咖啡香從吧台飄向窗邊座位，甜點櫃裡擺著當季蛋糕。這裡適合短暫休息、工作、約會，也適合和某個人慢慢聊起近況。',
   '最新消息', '今日甜點的話題', '本週末推出季節限定飲品。', false, 1, 8, true),
  ('park', '中央公園', '🌳', 750, 766, '城市裡的一片綠意',
   '步道穿過樹蔭與草地，長椅、噴水池和開闊的天空讓人暫時遠離喧鬧。清晨散步、午後閒聊或傍晚慢跑，都有不同的城市風景。',
   '最新消息', '公園活動公告', '傍晚時段適合散步，中央步道照明已開啟。', false, 1, 9, true)
ON CONFLICT (location_key) DO NOTHING;

-- Manual Preview testing first enqueues eligible public characters. The Edge Function
-- calls this only after its test-mode and account-allowlist checks; no Cron is enabled.
CREATE OR REPLACE FUNCTION public.enqueue_encounter_schedule_generation_test_batch(
  p_limit integer DEFAULT 500
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $
DECLARE
  v_character record;
  v_result jsonb;
  v_limit integer := pg_catalog.greatest(1, pg_catalog.least(COALESCE(p_limit, 500), 500));
  v_scanned integer := 0;
  v_pending integer := 0;
  v_unchanged integer := 0;
  v_not_eligible integer := 0;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  FOR v_character IN
    SELECT c.id
    FROM public.characters c
    CROSS JOIN LATERAL (
      SELECT public.encounter_schedule_source_payload(c.id) AS payload
    ) source
    WHERE c.visibility = 'public'
      AND c.review_status = 'approved'
      AND c.rights_confirmed IS TRUE
      AND c.deleted_at IS NULL
      AND c.is_nsfw IS FALSE
      AND NOT (
        pg_catalog.concat_ws(' ', c.intro, c.race, c.style)
          ~ '(ancient|historical|medieval|antiquity|fantasy|mythic|fictional|古代|歷史|中世紀|中古|奇幻|架空|封建|戰國|春秋|秦漢|唐代|宋代|明代|清代|古羅馬|古希臘)'
        AND COALESCE((source.payload->>'modern_setting_compatible')::boolean, false) IS NOT TRUE
        AND COALESCE((source.payload->>'time_travel_explicit')::boolean, false) IS NOT TRUE
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.encounter_schedule_generation_jobs j
        WHERE j.character_id = c.id
          AND j.status = 'processing'
          AND j.lease_expires_at > pg_catalog.clock_timestamp()
      )
    ORDER BY c.first_published_at NULLS LAST, c.id
    LIMIT v_limit
  LOOP
    v_scanned := v_scanned + 1;
    v_result := public.enqueue_encounter_schedule_generation_internal(v_character.id);
    CASE COALESCE(v_result->>'status', '')
      WHEN 'pending' THEN v_pending := v_pending + 1;
      WHEN 'not_eligible' THEN v_not_eligible := v_not_eligible + 1;
      ELSE v_unchanged := v_unchanged + 1;
    END CASE;
  END LOOP;

  RETURN pg_catalog.jsonb_build_object(
    'scanned_character_count', v_scanned,
    'pending_character_count', v_pending,
    'unchanged_character_count', v_unchanged,
    'not_eligible_character_count', v_not_eligible,
    'limit', v_limit
  );
END;
$;

REVOKE ALL ON FUNCTION public.enqueue_encounter_schedule_generation_test_batch(integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.enqueue_encounter_schedule_generation_test_batch(integer)
  TO service_role;

COMMENT ON FUNCTION public.enqueue_encounter_schedule_generation_test_batch(integer) IS
  'Preview/manual-only enqueue helper. Edge Function must enforce ENCOUNTER_SCHEDULE_TEST_MODE and account allowlist before calling. It only queues eligible public non-NSFW characters; it never invokes AI or workers.';

-- New dynamic locations use fixed, reviewed coordinates. AI cannot write coordinates.
CREATE OR REPLACE FUNCTION public.publish_encounter_scene_metadata(p_scenes jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_scene jsonb;
  v_key text;
  v_name text;
  v_icon text;
  v_heading text;
  v_description text;
  v_event_label text;
  v_event_title text;
  v_event_description text;
  v_dynamic boolean;
  v_x integer;
  v_y integer;
  v_count integer;
  v_published integer := 0;
  v_skipped integer := 0;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_scenes) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'scene_metadata_array_invalid' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_scenes) > 26 THEN
    RAISE EXCEPTION 'scene_metadata_array_invalid' USING ERRCODE = '22023';
  END IF;
  IF (
    SELECT pg_catalog.count(*) FROM jsonb_array_elements(p_scenes)
  ) <> (
    SELECT pg_catalog.count(DISTINCT value->>'location_key')
    FROM jsonb_array_elements(p_scenes)
  ) THEN
    RAISE EXCEPTION 'scene_metadata_duplicate_location_key' USING ERRCODE = '22023';
  END IF;

  FOR v_scene IN SELECT value FROM jsonb_array_elements(p_scenes)
  LOOP
    IF jsonb_typeof(v_scene) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'scene_metadata_shape_invalid' USING ERRCODE = '22023';
    END IF;
    IF (SELECT count(*) FROM jsonb_object_keys(v_scene)) <> 8 THEN
      RAISE EXCEPTION 'scene_metadata_shape_invalid' USING ERRCODE = '22023';
    END IF;

    v_key := pg_catalog.btrim(COALESCE(v_scene->>'location_key', ''));
    v_name := pg_catalog.btrim(COALESCE(v_scene->>'display_name', ''));
    v_icon := pg_catalog.btrim(COALESCE(v_scene->>'icon', ''));
    v_heading := pg_catalog.btrim(COALESCE(v_scene->>'heading', ''));
    v_description := pg_catalog.btrim(COALESCE(v_scene->>'description', ''));
    v_event_label := pg_catalog.btrim(COALESCE(v_scene->>'event_label', ''));
    v_event_title := pg_catalog.btrim(COALESCE(v_scene->>'event_title', ''));
    v_event_description := pg_catalog.btrim(COALESCE(v_scene->>'event_description', ''));

    IF COALESCE(v_key, '') NOT IN (
      'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
      'department-store', 'bookstore', 'cafe', 'park', 'shopping-street',
      'night-market', 'restaurant', 'university', 'hospital', 'gym', 'cinema',
      'museum', 'hotel', 'train-station', 'library', 'theater', 'art-gallery',
      'community-center', 'music-studio', 'bakery', 'coworking-space'
    )
       OR pg_catalog.char_length(v_name) NOT BETWEEN 1 AND 32
       OR pg_catalog.char_length(v_icon) NOT BETWEEN 1 AND 4
       OR v_icon ~ '[<>]'
       OR pg_catalog.char_length(v_heading) NOT BETWEEN 2 AND 50
       OR pg_catalog.char_length(v_description) NOT BETWEEN 30 AND 500
       OR pg_catalog.char_length(v_event_label) NOT BETWEEN 2 AND 20
       OR pg_catalog.char_length(v_event_title) NOT BETWEEN 2 AND 80
       OR pg_catalog.char_length(v_event_description) NOT BETWEEN 2 AND 160 THEN
      RAISE EXCEPTION 'scene_metadata_value_invalid' USING ERRCODE = '22023';
    END IF;

    v_dynamic := v_key IN (
      'shopping-street', 'night-market', 'restaurant', 'university', 'hospital',
      'gym', 'cinema', 'museum', 'hotel', 'train-station', 'library', 'theater',
      'art-gallery', 'community-center', 'music-studio', 'bakery', 'coworking-space'
    );

    IF v_dynamic THEN
      SELECT pg_catalog.count(DISTINCT c.id)::integer INTO v_count
      FROM public.character_schedules s
      JOIN public.characters c ON c.id = s.character_id
      WHERE s.location_key = v_key
        AND s.is_active IS TRUE
        AND s.source_type IN ('manual', 'ai')
        AND s.special_event_key IS NULL
        AND c.visibility = 'public'
        AND c.review_status = 'approved'
        AND c.rights_confirmed IS TRUE
        AND c.deleted_at IS NULL;
      IF COALESCE(v_count, 0) < 2 THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      CASE v_key
        WHEN 'shopping-street' THEN v_x := 1230; v_y := 620;
        WHEN 'night-market' THEN v_x := 390; v_y := 150;
        WHEN 'restaurant' THEN v_x := 550; v_y := 150;
        WHEN 'university' THEN v_x := 710; v_y := 150;
        WHEN 'hospital' THEN v_x := 870; v_y := 150;
        WHEN 'gym' THEN v_x := 1030; v_y := 150;
        WHEN 'cinema' THEN v_x := 1190; v_y := 230;
        WHEN 'museum' THEN v_x := 1430; v_y := 230;
        WHEN 'hotel' THEN v_x := 150; v_y := 310;
        WHEN 'train-station' THEN v_x := 310; v_y := 310;
        WHEN 'library' THEN v_x := 470; v_y := 310;
        WHEN 'theater' THEN v_x := 1190; v_y := 390;
        WHEN 'art-gallery' THEN v_x := 1350; v_y := 390;
        WHEN 'community-center' THEN v_x := 150; v_y := 470;
        WHEN 'music-studio' THEN v_x := 310; v_y := 470;
        WHEN 'bakery' THEN v_x := 470; v_y := 470;
        WHEN 'coworking-space' THEN v_x := 1030; v_y := 470;
        ELSE
          v_skipped := v_skipped + 1;
          CONTINUE;
      END CASE;
    ELSE
      CASE v_key
        WHEN 'airport' THEN v_x := 220; v_y := 140;
        WHEN 'commercial' THEN v_x := 1305; v_y := 94;
        WHEN 'night-bar' THEN v_x := 632; v_y := 294;
        WHEN 'live-house' THEN v_x := 868; v_y := 416;
        WHEN 'apartment' THEN v_x := 666; v_y := 440;
        WHEN 'department-store' THEN v_x := 1020; v_y := 300;
        WHEN 'bookstore' THEN v_x := 480; v_y := 733;
        WHEN 'cafe' THEN v_x := 645; v_y := 624;
        WHEN 'park' THEN v_x := 750; v_y := 766;
        ELSE
          v_skipped := v_skipped + 1;
          CONTINUE;
      END CASE;
      v_count := 0;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.encounter_scene_registry r
      WHERE r.is_active IS TRUE
        AND r.location_key <> v_key
        AND pg_catalog.sqrt(
          pg_catalog.power(r.marker_x - v_x, 2) +
          pg_catalog.power(r.marker_y - v_y, 2)
        ) < 120
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    INSERT INTO public.encounter_scene_registry (
      location_key, display_name, icon, marker_x, marker_y,
      heading, description, event_label, event_title, event_description,
      is_dynamic, minimum_character_count, display_order, is_active
    ) VALUES (
      v_key, v_name, v_icon, v_x, v_y, v_heading, v_description,
      v_event_label, v_event_title, v_event_description,
      v_dynamic, CASE WHEN v_dynamic THEN 2 ELSE 1 END,
      CASE WHEN v_dynamic THEN 10 ELSE 100 END, true
    )
    ON CONFLICT (location_key) DO UPDATE
    SET display_name = EXCLUDED.display_name,
        icon = EXCLUDED.icon,
        heading = EXCLUDED.heading,
        description = EXCLUDED.description,
        event_label = EXCLUDED.event_label,
        event_title = EXCLUDED.event_title,
        event_description = EXCLUDED.event_description,
        is_dynamic = EXCLUDED.is_dynamic,
        minimum_character_count = EXCLUDED.minimum_character_count,
        display_order = EXCLUDED.display_order,
        is_active = true,
        updated_at = pg_catalog.clock_timestamp();
    v_published := v_published + 1;
  END LOOP;

  RETURN pg_catalog.jsonb_build_object(
    'published_scene_count', v_published,
    'skipped_scene_count', v_skipped
  );
END;
$$;

REVOKE ALL ON FUNCTION public.publish_encounter_scene_metadata(jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.publish_encounter_scene_metadata(jsonb)
  TO service_role;

CREATE OR REPLACE FUNCTION public.get_encounter_scene_catalog()
RETURNS TABLE (
  location_key text,
  display_name text,
  icon text,
  marker_x integer,
  marker_y integer,
  heading text,
  description text,
  event_label text,
  event_title text,
  event_description text,
  is_dynamic boolean,
  character_count bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH scene_counts AS (
    SELECT
      r.location_key, r.display_name, r.icon, r.marker_x, r.marker_y,
      r.heading, r.description, r.event_label, r.event_title,
      r.event_description, r.is_dynamic, r.minimum_character_count,
      r.display_order,
      pg_catalog.count(DISTINCT c.id) AS character_count
    FROM public.encounter_scene_registry r
    LEFT JOIN public.character_schedules s
      ON s.location_key = r.location_key
     AND s.is_active IS TRUE
     AND s.source_type IN ('manual', 'ai')
     AND s.special_event_key IS NULL
    LEFT JOIN public.characters c
      ON c.id = s.character_id
     AND c.visibility = 'public'
     AND c.review_status = 'approved'
     AND c.rights_confirmed IS TRUE
     AND c.deleted_at IS NULL
    WHERE r.is_active IS TRUE
    GROUP BY
      r.location_key, r.display_name, r.icon, r.marker_x, r.marker_y,
      r.heading, r.description, r.event_label, r.event_title,
      r.event_description, r.is_dynamic, r.minimum_character_count,
      r.display_order
  ),
  eligible AS (
    SELECT *,
      pg_catalog.row_number() OVER (
        PARTITION BY is_dynamic
        ORDER BY display_order, character_count DESC, location_key
      ) AS scene_rank
    FROM scene_counts
    WHERE is_dynamic IS FALSE OR character_count >= minimum_character_count
  )
  SELECT
    location_key, display_name, icon, marker_x, marker_y, heading,
    description, event_label, event_title, event_description,
    is_dynamic, character_count
  FROM eligible
  WHERE is_dynamic IS FALSE OR scene_rank <= 3
  ORDER BY is_dynamic, display_order, location_key;
$$;

REVOKE ALL ON FUNCTION public.get_encounter_scene_catalog()
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_encounter_scene_catalog()
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.get_encounter_scene_catalog() IS
  'Returns built-in scene copy for existing map markers plus up to three dynamic scene markers backed by at least two distinct eligible public characters. AI never controls marker coordinates.';

CREATE OR REPLACE FUNCTION public.resolve_encounter_character_schedule(
  p_character_id uuid,
  p_user_id uuid DEFAULT auth.uid(),
  p_location_key text DEFAULT NULL,
  p_at timestamptz DEFAULT pg_catalog.now()
)
RETURNS TABLE (
  schedule_id uuid,
  weekday smallint,
  day_type text,
  start_time time,
  end_time time,
  location_key text,
  activity text,
  priority smallint,
  source_type text,
  variant_key text,
  variant_weight smallint,
  encounter_greeting text,
  is_outdoor boolean,
  rain_fallback_location_key text,
  rain_fallback_activity text,
  rain_fallback_greeting text,
  scheduled_start_at timestamptz,
  scheduled_end_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_local timestamp;
  v_local_date date;
  v_local_time time;
  v_schedule_date date;
  v_schedule_day integer;
  v_day_type text;
  v_special_event_key text;
  v_variant_roll integer;
  v_primary_weight integer;
  v_variant_key text;
  v_is_raining boolean := false;
  v_weather_text text := '多雲';
  v_row public.character_schedules%ROWTYPE;
  v_decision public.encounter_schedule_weather_decisions%ROWTYPE;
  v_effective_location text;
  v_effective_activity text;
  v_effective_greeting text;
  v_effective_is_outdoor boolean;
  v_start_local timestamp;
  v_end_local timestamp;
BEGIN
  v_local := p_at AT TIME ZONE 'Asia/Taipei';
  v_local_date := v_local::date;
  v_local_time := v_local::time;
  SELECT weather.is_raining, weather.weather_text
    INTO v_is_raining, v_weather_text
  FROM public.get_encounter_city_weather() AS weather;
  v_is_raining := COALESCE(v_is_raining, false);
  v_weather_text := COALESCE(v_weather_text, '多雲');

  -- Keep only recent decisions; old schedule occurrences are no longer resolvable.
  DELETE FROM public.encounter_schedule_weather_decisions d
  USING public.character_schedules s
  WHERE d.schedule_id = s.id
    AND s.character_id = p_character_id
    AND d.scheduled_end_at < (p_at - interval '2 days');

  FOR v_row IN
    SELECT s.*
    FROM public.characters c
    JOIN public.character_schedules s ON s.character_id = c.id
    WHERE c.id = p_character_id
      AND c.visibility = 'public'
      AND c.deleted_at IS NULL
      AND c.review_status = 'approved'
      AND c.rights_confirmed IS TRUE
      AND (
        c.is_nsfw IS NOT TRUE
        OR EXISTS (
          SELECT 1 FROM public.profiles p
          WHERE p.id = p_user_id
            AND p.birthdate IS NOT NULL
            AND p.birthdate <= (CURRENT_DATE - interval '18 years')::date
        )
      )
      AND s.is_active IS TRUE
      -- Ignore the old pre-AI placeholder rows (all-day, every-place, priority 0).
      -- Keep the historical rows intact; only prevent them from being treated as live schedules.
      AND NOT (
        s.source_type = 'legacy'
        AND s.start_time = TIME '00:00'
        AND s.end_time = TIME '23:59'
        AND COALESCE(s.priority, 0) = 0
      )
      AND (
        (s.start_time < s.end_time AND v_local_time >= s.start_time AND v_local_time < s.end_time)
        OR
        (s.start_time > s.end_time AND (v_local_time >= s.start_time OR v_local_time < s.end_time))
      )
    ORDER BY
      CASE s.source_type WHEN 'manual' THEN 3 WHEN 'ai' THEN 2 ELSE 1 END DESC,
      CASE s.special_event_key
        WHEN 'lunar_new_year' THEN 4
        WHEN 'valentines_day' THEN 4
        WHEN 'christmas' THEN 4
        WHEN 'taiwan_public_holiday' THEN 3
        ELSE 0
      END DESC,
      s.priority DESC,
      s.start_time
  LOOP
    v_schedule_date := CASE
      WHEN v_row.start_time > v_row.end_time AND v_local_time < v_row.end_time
        THEN v_local_date - 1
      ELSE v_local_date
    END;
    v_schedule_day := EXTRACT(DOW FROM v_schedule_date)::integer;

    SELECT CASE
      WHEN d.day_type = 'workday' THEN 'weekday'
      WHEN d.day_type = 'holiday' THEN 'holiday'
      WHEN d.calendar_date IS NULL AND v_schedule_day IN (0, 6) THEN 'holiday'
      ELSE 'weekday'
    END INTO v_day_type
    FROM (SELECT v_schedule_date AS calendar_date) current_day
    LEFT JOIN public.taiwan_calendar_days d ON d.calendar_date = current_day.calendar_date;

    v_special_event_key := public.resolve_encounter_special_event_key(v_schedule_date);
    IF v_row.special_event_key IS NOT NULL THEN
      IF v_row.special_event_key IS DISTINCT FROM v_special_event_key
         AND NOT (
           v_row.special_event_key = 'taiwan_public_holiday'
           AND EXISTS (
             SELECT 1
             FROM public.taiwan_calendar_days d
             WHERE d.calendar_date = v_schedule_date
               AND d.day_type = 'holiday'
               AND NULLIF(pg_catalog.btrim(d.holiday_name), '') IS NOT NULL
           )
         ) THEN
        CONTINUE;
      END IF;
    ELSIF v_row.source_type = 'ai' THEN
      IF v_row.day_type <> v_day_type THEN CONTINUE; END IF;
      SELECT s.variant_weight INTO v_primary_weight
      FROM public.character_schedules s
      WHERE s.character_id = p_character_id
        AND s.source_type = 'ai'
        AND s.is_active IS TRUE
        AND s.day_type = v_day_type
        AND s.variant_key = 'primary'
        AND s.special_event_key IS NULL
      ORDER BY s.priority DESC, s.start_time
      LIMIT 1;
      v_primary_weight := COALESCE(v_primary_weight, CASE WHEN v_day_type = 'weekday' THEN 80 ELSE 60 END);
      v_variant_roll := pg_catalog.mod(
        pg_catalog.abs(pg_catalog.hashtext(p_character_id::text || v_schedule_date::text || v_day_type)::bigint),
        100
      )::integer;
      v_variant_key := CASE WHEN v_variant_roll < v_primary_weight THEN 'primary' ELSE 'alternative' END;
      IF v_row.variant_key <> v_variant_key THEN CONTINUE; END IF;
    ELSE
      IF v_row.weekday IS NOT NULL AND v_row.weekday <> v_schedule_day THEN CONTINUE; END IF;
      IF NOT (
        v_row.day_type = 'any'
        OR (v_row.day_type = 'weekday' AND v_day_type = 'weekday')
        OR (v_row.day_type = 'weekend' AND v_schedule_day IN (0, 6))
        OR (v_row.day_type = 'holiday' AND v_day_type = 'holiday')
      ) THEN CONTINUE; END IF;
    END IF;

    v_start_local := v_schedule_date + v_row.start_time;
    v_end_local := v_schedule_date + v_row.end_time
      + CASE WHEN v_row.end_time <= v_row.start_time THEN interval '1 day' ELSE interval '0' END;

    SELECT * INTO v_decision
    FROM public.encounter_schedule_weather_decisions d
    WHERE d.schedule_id = v_row.id
      AND d.scheduled_start_at = (v_start_local AT TIME ZONE 'Asia/Taipei');

    IF NOT FOUND THEN
      v_effective_location := CASE
        WHEN v_is_raining IS TRUE AND v_row.is_outdoor IS TRUE
          THEN COALESCE(v_row.rain_fallback_location_key, v_row.location_key)
        ELSE v_row.location_key END;
      v_effective_activity := CASE
        WHEN v_is_raining IS TRUE AND v_row.is_outdoor IS TRUE
          THEN COALESCE(v_row.rain_fallback_activity, v_row.activity)
        ELSE v_row.activity END;
      v_effective_greeting := CASE
        WHEN v_is_raining IS TRUE AND v_row.is_outdoor IS TRUE
          THEN COALESCE(v_row.rain_fallback_greeting, v_row.encounter_greeting)
        ELSE v_row.encounter_greeting END;
      v_effective_is_outdoor := CASE
        WHEN v_is_raining IS TRUE AND v_row.is_outdoor IS TRUE
          THEN false ELSE v_row.is_outdoor END;

      INSERT INTO public.encounter_schedule_weather_decisions (
        schedule_id, scheduled_start_at, scheduled_end_at, location_key, activity,
        encounter_greeting, is_outdoor, decided_weather_text, decided_is_raining
      ) VALUES (
        v_row.id, (v_start_local AT TIME ZONE 'Asia/Taipei'),
        (v_end_local AT TIME ZONE 'Asia/Taipei'),
        v_effective_location, v_effective_activity, v_effective_greeting,
        v_effective_is_outdoor, v_weather_text, v_is_raining
      ) ON CONFLICT ON CONSTRAINT encounter_schedule_weather_decisions_pkey DO NOTHING;

      SELECT * INTO v_decision
      FROM public.encounter_schedule_weather_decisions d
      WHERE d.schedule_id = v_row.id
        AND d.scheduled_start_at = (v_start_local AT TIME ZONE 'Asia/Taipei');
    END IF;

    IF p_location_key IS NOT NULL AND v_decision.location_key <> p_location_key THEN
      CONTINUE;
    END IF;

    RETURN QUERY SELECT
      v_row.id,
      v_schedule_day::smallint,
      v_day_type,
      v_row.start_time,
      v_row.end_time,
      v_decision.location_key,
      v_decision.activity,
      v_row.priority,
      v_row.source_type,
      v_row.variant_key,
      v_row.variant_weight,
      v_decision.encounter_greeting,
      v_decision.is_outdoor,
      v_row.rain_fallback_location_key,
      v_row.rain_fallback_activity,
      v_row.rain_fallback_greeting,
      v_start_local AT TIME ZONE 'Asia/Taipei',
      v_end_local AT TIME ZONE 'Asia/Taipei';
    RETURN;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_encounter_character_schedule(uuid, uuid, text, timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_encounter_character_schedule(uuid, uuid, text, timestamptz)
  TO service_role;

CREATE OR REPLACE FUNCTION public.publish_encounter_schedule_batch(
  p_batch_id uuid,
  p_lease_token uuid,
  p_characters jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_batch public.encounter_schedule_batch_runs%ROWTYPE;
  v_item jsonb;
  v_variant jsonb;
  v_slot jsonb;
  v_special_event jsonb;
  v_special_slot jsonb;
  v_special_event_key text;
  v_special_event_name text;
  v_character_id uuid;
  v_job public.encounter_schedule_generation_jobs%ROWTYPE;
  v_source jsonb;
  v_current_hash text;
  v_placement text;
  v_greeting_pool jsonb;
  v_day_type text;
  v_published integer := 0;
  v_unplaced integer := 0;
  v_skipped integer := 0;
  v_output_count integer := 0;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_characters) <> 'array' THEN
    RAISE EXCEPTION 'schedule_batch_output_must_be_array' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_batch
  FROM public.encounter_schedule_batch_runs b
  WHERE b.id = p_batch_id AND b.lease_token = p_lease_token AND b.status = 'processing'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'schedule_batch_lease_not_found' USING ERRCODE = '40001';
  END IF;

  SELECT COUNT(*) INTO v_output_count FROM jsonb_array_elements(p_characters);
  IF v_output_count <> pg_catalog.cardinality(v_batch.character_ids) THEN
    RAISE EXCEPTION 'schedule_batch_character_count_mismatch' USING ERRCODE = '22023';
  END IF;

  IF (
    SELECT COUNT(DISTINCT value->>'character_id')
    FROM jsonb_array_elements(p_characters)
  ) <> v_output_count THEN
    RAISE EXCEPTION 'schedule_batch_duplicate_character' USING ERRCODE = '22023';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_characters)
  LOOP
    v_character_id := (v_item->>'character_id')::uuid;
    IF NOT (v_character_id = ANY(v_batch.character_ids)) THEN
      RAISE EXCEPTION 'schedule_batch_contains_unclaimed_character' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_job
    FROM public.encounter_schedule_generation_jobs j
    WHERE j.character_id = v_character_id
      AND j.lease_token = p_lease_token
      AND j.status = 'processing'
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'schedule_character_lease_mismatch' USING ERRCODE = '40001';
    END IF;

    v_source := public.encounter_schedule_source_payload(v_character_id);
    IF v_source IS NULL THEN
      UPDATE public.encounter_schedule_generation_jobs
      SET status = 'cancelled', lease_token = NULL, lease_expires_at = NULL,
          last_error_code = 'character_no_longer_public', updated_at = pg_catalog.clock_timestamp()
      WHERE character_id = v_character_id;
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_current_hash := pg_catalog.md5(v_source::text);
    IF v_current_hash IS DISTINCT FROM v_job.source_hash THEN
      UPDATE public.encounter_schedule_generation_jobs
      SET source_hash = v_current_hash, status = 'pending',
          queued_at = pg_catalog.clock_timestamp(), available_at = pg_catalog.clock_timestamp(),
          lease_token = NULL, lease_expires_at = NULL,
          lease_generation = lease_generation + 1, attempt_count = 0,
          last_error_code = 'source_changed_during_generation', updated_at = pg_catalog.clock_timestamp()
      WHERE character_id = v_character_id;
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_placement := v_item->>'placement';
    IF v_placement = 'no_matching_location' THEN
      IF jsonb_typeof(v_item->'special_events') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'unplaced_character_special_events_must_be_empty' USING ERRCODE = '22023';
      END IF;
      IF jsonb_array_length(v_item->'special_events') <> 0 THEN
        RAISE EXCEPTION 'unplaced_character_special_events_must_be_empty' USING ERRCODE = '22023';
      END IF;
      UPDATE public.character_schedules
      SET is_active = false, updated_at = pg_catalog.clock_timestamp()
      WHERE character_id = v_character_id AND source_type IN ('ai', 'legacy') AND is_active IS TRUE;

      DELETE FROM public.encounter_character_greeting_pools
      WHERE character_id = v_character_id;

      UPDATE public.encounter_schedule_generation_jobs
      SET status = 'completed', last_completed_source_hash = v_job.source_hash,
          completed_at = pg_catalog.clock_timestamp(), lease_token = NULL, lease_expires_at = NULL,
          last_error_code = NULL, updated_at = pg_catalog.clock_timestamp()
      WHERE character_id = v_character_id;
      v_unplaced := v_unplaced + 1;
      CONTINUE;
    END IF;

    IF v_placement <> 'modern_map' THEN
      RAISE EXCEPTION 'schedule_placement_invalid' USING ERRCODE = '22023';
    END IF;

    v_greeting_pool := v_item->'relationship_greetings';
    IF jsonb_typeof(v_greeting_pool) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'schedule_relationship_greeting_pools_invalid' USING ERRCODE = '22023';
    END IF;
    IF (SELECT count(*) FROM jsonb_object_keys(v_greeting_pool)) <> 8
       OR EXISTS (
         SELECT 1
         FROM jsonb_each(v_greeting_pool) AS pool(stage, greetings)
         WHERE pool.stage NOT IN (
           'hostile', 'dislike', 'wary', 'first_meeting',
           'acquaintance', 'close', 'intimate', 'special'
         )
         OR CASE
           WHEN jsonb_typeof(pool.greetings) IS DISTINCT FROM 'array' THEN true
           ELSE jsonb_array_length(pool.greetings) NOT BETWEEN 3 AND 5
             OR EXISTS (
               SELECT 1
               FROM jsonb_array_elements(pool.greetings) AS item(value)
               WHERE jsonb_typeof(item.value) IS DISTINCT FROM 'string'
                  OR pg_catalog.char_length(item.value #>> '{}') NOT BETWEEN 150 AND 300
             )
             OR (
               SELECT count(DISTINCT item.value #>> '{}')
               FROM jsonb_array_elements(pool.greetings) AS item(value)
             ) <> jsonb_array_length(pool.greetings)
         END
       ) THEN
      RAISE EXCEPTION 'schedule_relationship_greeting_pools_invalid' USING ERRCODE = '22023';
    END IF;

    UPDATE public.character_schedules
    SET is_active = false, updated_at = pg_catalog.clock_timestamp()
    WHERE character_id = v_character_id AND source_type IN ('ai', 'legacy') AND is_active IS TRUE;

    FOREACH v_day_type IN ARRAY ARRAY['weekday', 'holiday']::text[]
    LOOP
      IF jsonb_typeof(v_item->'variants'->v_day_type) <> 'array'
         OR jsonb_array_length(v_item->'variants'->v_day_type) <> 2 THEN
        RAISE EXCEPTION 'schedule_variants_invalid' USING ERRCODE = '22023';
      END IF;

      FOR v_variant IN SELECT value FROM jsonb_array_elements(v_item->'variants'->v_day_type)
      LOOP
        IF (v_day_type = 'weekday' AND (
              (v_variant->>'variant_key' = 'primary' AND (v_variant->>'weight')::integer <> 80)
              OR (v_variant->>'variant_key' = 'alternative' AND (v_variant->>'weight')::integer <> 20)
            ))
           OR (v_day_type = 'holiday' AND (
              (v_variant->>'variant_key' = 'primary' AND (v_variant->>'weight')::integer <> 60)
              OR (v_variant->>'variant_key' = 'alternative' AND (v_variant->>'weight')::integer <> 40)
            )) THEN
          RAISE EXCEPTION 'schedule_variant_weight_invalid' USING ERRCODE = '22023';
        END IF;

        IF v_variant->>'variant_key' NOT IN ('primary', 'alternative')
           OR jsonb_typeof(v_variant->'slots') <> 'array'
           OR jsonb_array_length(v_variant->'slots') NOT BETWEEN 2 AND 4 THEN
          RAISE EXCEPTION 'schedule_variant_shape_invalid' USING ERRCODE = '22023';
        END IF;

        FOR v_slot IN SELECT value FROM jsonb_array_elements(v_variant->'slots')
        LOOP
          IF COALESCE(v_slot->>'start_time', '') !~ '^([01][0-9]|2[0-3]):00$'
             OR COALESCE(v_slot->>'end_time', '') !~ '^([01][0-9]|2[0-3]):00$'
             OR v_slot->>'start_time' = v_slot->>'end_time'
             OR COALESCE(v_slot->>'location_key', '') NOT IN ('airport', 'commercial', 'night-bar', 'live-house', 'apartment', 'department-store', 'bookstore', 'cafe', 'park', 'shopping-street', 'night-market', 'restaurant', 'university', 'hospital', 'gym', 'cinema', 'museum', 'hotel', 'train-station', 'library', 'theater', 'art-gallery', 'community-center', 'music-studio', 'bakery', 'coworking-space')
             OR char_length(COALESCE(v_slot->>'activity', '')) NOT BETWEEN 1 AND 200
             OR char_length(COALESCE(v_slot->>'encounter_greeting', '')) NOT BETWEEN 150 AND 300 THEN
            RAISE EXCEPTION 'schedule_slot_invalid' USING ERRCODE = '22023';
          END IF;

          IF COALESCE((v_slot->>'is_outdoor')::boolean, false) IS TRUE THEN
            IF COALESCE(v_slot->>'rain_fallback_location_key', '') NOT IN ('airport', 'commercial', 'night-bar', 'live-house', 'apartment', 'department-store', 'bookstore', 'cafe', 'restaurant', 'university', 'hospital', 'gym', 'cinema', 'museum', 'hotel', 'train-station', 'library', 'theater', 'art-gallery', 'community-center', 'music-studio', 'bakery', 'coworking-space')
               OR char_length(COALESCE(v_slot->>'rain_fallback_activity', '')) NOT BETWEEN 1 AND 200
               OR char_length(COALESCE(v_slot->>'rain_fallback_greeting', '')) NOT BETWEEN 150 AND 300 THEN
              RAISE EXCEPTION 'schedule_rain_fallback_invalid' USING ERRCODE = '22023';
            END IF;
          ELSE
            IF v_slot->>'rain_fallback_location_key' IS NOT NULL
               OR v_slot->>'rain_fallback_activity' IS NOT NULL
               OR v_slot->>'rain_fallback_greeting' IS NOT NULL THEN
              RAISE EXCEPTION 'schedule_unexpected_rain_fallback' USING ERRCODE = '22023';
            END IF;
          END IF;

          -- Every daily variant must cover 00:00 through the next 00:00
          -- without gaps. A final 22:00-00:00 slot is represented as a wrap to midnight.
          IF EXISTS (
            WITH intervals AS (
              SELECT
                (EXTRACT(HOUR FROM (slot->>'start_time')::time)::integer * 60) AS start_minute,
                (EXTRACT(HOUR FROM (slot->>'end_time')::time)::integer * 60)
                  + CASE
                      WHEN (slot->>'end_time')::time <= (slot->>'start_time')::time THEN 1440
                      ELSE 0
                    END AS end_minute
              FROM jsonb_array_elements(v_variant->'slots') AS slots(slot)
            ),
            ordered AS (
              SELECT start_minute, end_minute,
                pg_catalog.lag(end_minute) OVER (ORDER BY start_minute) AS previous_end
              FROM intervals
            ),
            coverage AS (
              SELECT
                pg_catalog.count(*) AS slot_count,
                pg_catalog.min(start_minute) AS first_start,
                pg_catalog.max(end_minute) AS final_end,
                pg_catalog.bool_or(previous_end IS NOT NULL AND previous_end <> start_minute) AS has_gap
              FROM ordered
            )
            SELECT 1 FROM coverage
            WHERE slot_count < 2 OR first_start <> 0 OR final_end <> 1440 OR COALESCE(has_gap, true)
          ) THEN
            RAISE EXCEPTION 'schedule_variant_24_hour_coverage_incomplete' USING ERRCODE = '22023';
          END IF;

          INSERT INTO public.character_schedules (
            character_id, weekday, day_type, start_time, end_time, location_key, activity,
            priority, is_active, source_type, variant_key, variant_weight,
            encounter_greeting, is_outdoor, rain_fallback_location_key,
            rain_fallback_activity, rain_fallback_greeting, batch_id, source_hash
          ) VALUES (
            v_character_id, NULL, v_day_type,
            (v_slot->>'start_time')::time, (v_slot->>'end_time')::time,
            v_slot->>'location_key', v_slot->>'activity',
            50, true, 'ai', v_variant->>'variant_key', (v_variant->>'weight')::smallint,
            v_slot->>'encounter_greeting', COALESCE((v_slot->>'is_outdoor')::boolean, false),
            NULLIF(v_slot->>'rain_fallback_location_key', ''),
            NULLIF(v_slot->>'rain_fallback_activity', ''),
            NULLIF(v_slot->>'rain_fallback_greeting', ''),
            p_batch_id, v_job.source_hash
          );
        END LOOP;
      END LOOP;
    END LOOP;

    IF jsonb_typeof(v_item->'special_events') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'schedule_special_events_invalid' USING ERRCODE = '22023';
    END IF;
    IF jsonb_array_length(v_item->'special_events') > 4 THEN
      RAISE EXCEPTION 'schedule_special_events_invalid' USING ERRCODE = '22023';
    END IF;

    IF (
      SELECT COUNT(DISTINCT event.value->>'event_key')
      FROM jsonb_array_elements(v_item->'special_events') AS event(value)
    ) <> jsonb_array_length(v_item->'special_events') THEN
      RAISE EXCEPTION 'schedule_special_event_duplicate' USING ERRCODE = '22023';
    END IF;

    FOR v_special_event IN
      SELECT value FROM jsonb_array_elements(v_item->'special_events')
    LOOP
      v_special_event_key := v_special_event->>'event_key';
      v_special_event_name := pg_catalog.btrim(COALESCE(v_special_event->>'event_name', ''));
      IF COALESCE(v_special_event_key, '') NOT IN ('taiwan_public_holiday', 'lunar_new_year', 'valentines_day', 'christmas')
         OR pg_catalog.char_length(v_special_event_name) NOT BETWEEN 1 AND 40
         OR jsonb_typeof(v_special_event->'slots') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'schedule_special_event_shape_invalid' USING ERRCODE = '22023';
      END IF;
      IF jsonb_array_length(v_special_event->'slots') NOT BETWEEN 2 AND 4 THEN
        RAISE EXCEPTION 'schedule_special_event_shape_invalid' USING ERRCODE = '22023';
      END IF;

      FOR v_special_slot IN
        SELECT value FROM jsonb_array_elements(v_special_event->'slots')
      LOOP
        IF COALESCE(v_special_slot->>'start_time', '') !~ '^([01][0-9]|2[0-3]):00$'
           OR COALESCE(v_special_slot->>'end_time', '') !~ '^([01][0-9]|2[0-3]):00$'
           OR v_special_slot->>'start_time' = v_special_slot->>'end_time'
           OR COALESCE(v_special_slot->>'location_key', '') NOT IN ('airport', 'commercial', 'night-bar', 'live-house', 'apartment', 'department-store', 'bookstore', 'cafe', 'park', 'shopping-street', 'night-market', 'restaurant', 'university', 'hospital', 'gym', 'cinema', 'museum', 'hotel', 'train-station', 'library', 'theater', 'art-gallery', 'community-center', 'music-studio', 'bakery', 'coworking-space')
           OR pg_catalog.char_length(COALESCE(v_special_slot->>'activity', '')) NOT BETWEEN 1 AND 200
           OR pg_catalog.char_length(COALESCE(v_special_slot->>'encounter_greeting', '')) NOT BETWEEN 150 AND 300
           OR jsonb_typeof(v_special_slot->'is_outdoor') IS DISTINCT FROM 'boolean' THEN
          RAISE EXCEPTION 'schedule_special_event_slot_invalid' USING ERRCODE = '22023';
        END IF;

        IF (v_special_slot->>'is_outdoor')::boolean IS TRUE THEN
          IF COALESCE(v_special_slot->>'rain_fallback_location_key', '') NOT IN ('airport', 'commercial', 'night-bar', 'live-house', 'apartment', 'department-store', 'bookstore', 'cafe', 'restaurant', 'university', 'hospital', 'gym', 'cinema', 'museum', 'hotel', 'train-station', 'library', 'theater', 'art-gallery', 'community-center', 'music-studio', 'bakery', 'coworking-space')
             OR pg_catalog.char_length(COALESCE(v_special_slot->>'rain_fallback_activity', '')) NOT BETWEEN 1 AND 200
             OR pg_catalog.char_length(COALESCE(v_special_slot->>'rain_fallback_greeting', '')) NOT BETWEEN 150 AND 300 THEN
            RAISE EXCEPTION 'schedule_special_event_rain_fallback_invalid' USING ERRCODE = '22023';
          END IF;
        ELSIF v_special_slot->>'rain_fallback_location_key' IS NOT NULL
           OR v_special_slot->>'rain_fallback_activity' IS NOT NULL
           OR v_special_slot->>'rain_fallback_greeting' IS NOT NULL THEN
          RAISE EXCEPTION 'schedule_special_event_unexpected_rain_fallback' USING ERRCODE = '22023';
        END IF;
      END LOOP;

      IF EXISTS (
        WITH intervals AS (
          SELECT
            EXTRACT(HOUR FROM (slot->>'start_time')::time)::integer * 60 AS start_minute,
            EXTRACT(HOUR FROM (slot->>'end_time')::time)::integer * 60
              + CASE WHEN (slot->>'end_time')::time <= (slot->>'start_time')::time THEN 1440 ELSE 0 END AS end_minute
          FROM jsonb_array_elements(v_special_event->'slots') AS slots(slot)
        ),
        ordered AS (
          SELECT start_minute, end_minute,
            pg_catalog.lag(end_minute) OVER (ORDER BY start_minute) AS previous_end
          FROM intervals
        ),
        coverage AS (
          SELECT pg_catalog.count(*) AS slot_count,
            pg_catalog.min(start_minute) AS first_start,
            pg_catalog.max(end_minute) AS final_end,
            pg_catalog.bool_or(previous_end IS NOT NULL AND previous_end <> start_minute) AS has_gap
          FROM ordered
        )
        SELECT 1 FROM coverage
        WHERE slot_count < 2 OR first_start <> 0 OR final_end <> 1440 OR COALESCE(has_gap, true)
      ) THEN
        RAISE EXCEPTION 'schedule_special_event_24_hour_coverage_incomplete' USING ERRCODE = '22023';
      END IF;

      FOR v_special_slot IN
        SELECT value FROM jsonb_array_elements(v_special_event->'slots')
      LOOP
        INSERT INTO public.character_schedules (
          character_id, weekday, day_type, start_time, end_time, location_key, activity,
          priority, is_active, source_type, variant_key, variant_weight, special_event_key,
          encounter_greeting, is_outdoor, rain_fallback_location_key,
          rain_fallback_activity, rain_fallback_greeting, batch_id, source_hash
        ) VALUES (
          v_character_id, NULL, 'any',
          (v_special_slot->>'start_time')::time, (v_special_slot->>'end_time')::time,
          v_special_slot->>'location_key', v_special_slot->>'activity',
          60, true, 'ai', 'special', 100, v_special_event_key,
          v_special_slot->>'encounter_greeting', (v_special_slot->>'is_outdoor')::boolean,
          NULLIF(v_special_slot->>'rain_fallback_location_key', ''),
          NULLIF(v_special_slot->>'rain_fallback_activity', ''),
          NULLIF(v_special_slot->>'rain_fallback_greeting', ''),
          p_batch_id, v_job.source_hash
        );
      END LOOP;
    END LOOP;

    INSERT INTO public.encounter_character_greeting_pools (
      character_id, source_hash, greeting_pools, generated_at, updated_at
    ) VALUES (
      v_character_id, v_job.source_hash, v_greeting_pool,
      pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp()
    )
    ON CONFLICT (character_id) DO UPDATE
    SET source_hash = EXCLUDED.source_hash,
        greeting_pools = EXCLUDED.greeting_pools,
        generated_at = EXCLUDED.generated_at,
        updated_at = EXCLUDED.updated_at;

    UPDATE public.encounter_schedule_generation_jobs
    SET status = 'completed', last_completed_source_hash = v_job.source_hash,
        completed_at = pg_catalog.clock_timestamp(), lease_token = NULL, lease_expires_at = NULL,
        last_error_code = NULL, updated_at = pg_catalog.clock_timestamp()
    WHERE character_id = v_character_id;
    v_published := v_published + 1;
  END LOOP;

  UPDATE public.encounter_schedule_batch_runs
  SET status = 'completed', completed_at = pg_catalog.clock_timestamp(),
      published_character_count = v_published, unplaced_character_count = v_unplaced,
      skipped_character_count = v_skipped, updated_at = pg_catalog.clock_timestamp()
  WHERE id = p_batch_id;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'completed',
    'published_character_count', v_published,
    'unplaced_character_count', v_unplaced,
    'skipped_private_character_count', v_skipped
  );
END;
$$;

REVOKE ALL ON FUNCTION public.publish_encounter_schedule_batch(uuid, uuid, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.publish_encounter_schedule_batch(uuid, uuid, jsonb)
  TO service_role;
