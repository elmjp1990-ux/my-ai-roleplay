BEGIN;

-- The city map uses fourteen permanent A–N anchors. Dynamic data may refresh
-- venue news, but it must not create, move, or hide map locations.
ALTER TABLE public.encounter_scene_backgrounds
  DROP CONSTRAINT IF EXISTS encounter_scene_backgrounds_location_key_check;

ALTER TABLE public.encounter_scene_backgrounds
  ADD CONSTRAINT encounter_scene_backgrounds_location_key_check
  CHECK (
    location_key = '*' OR location_key IN (
      'waterfront', 'commercial', 'airport', 'university', 'park',
      'shopping-street', 'department-store', 'hospital', 'night-bar',
      'live-house', 'luxury-apartment', 'apartment', 'convenience-store',
      'private-club', 'bookstore', 'cafe', 'night-market', 'restaurant',
      'gym', 'cinema', 'museum', 'hotel', 'train-station', 'library',
      'theater', 'art-gallery', 'community-center', 'music-studio',
      'bakery', 'coworking-space'
    )
  );

INSERT INTO public.encounter_scene_registry (
  location_key, display_name, icon, marker_x, marker_y, heading, description,
  event_label, event_title, event_description, is_dynamic,
  minimum_character_count, display_order, is_active
) VALUES
  ('waterfront', '水岸港區', '🌊', 1392, 638, '沿著河岸與港灣散步',
   '河堤步道、碼頭與水岸景觀連接城市不同區域，白天適合散步與吹風，夜晚則能欣賞水面與城市燈光。',
   '場景亮點', '水岸邊的偶遇', '適合散步、談心、看夜景或在河堤旁短暫停留。', false, 1, 1, true),
  ('commercial', '辦公大樓', '🏢', 1303, 44, '玻璃帷幕下的繁忙日常',
   '電梯穿梭於不同樓層，會議室、辦公座位與窗邊休息區構成城市工作的節奏。白天忙碌，傍晚後則逐漸安靜。',
   '場景亮點', '下班後的窗邊時光', '適合商業談判、同事互動、秘密會面或忙碌一天後的短暫休息。', false, 1, 2, true),
  ('airport', '機場', '✈️', 425, 124, '城市的起點與交會處',
   '航班資訊在大廳螢幕上流動，旅人拖著行李匆匆經過。候機座位、接機大廳與深夜航班，總有新的相遇可能。',
   '場景亮點', '抵達大廳的偶遇', '適合安排接機、送別、轉機途中或旅程開始前的故事。', false, 1, 3, true),
  ('university', '校園', '🎓', 280, 365, '校園裡的日常與青春',
   '教學大樓、圖書館、操場與校園廣場構成日常動線，下課鐘聲與社團活動讓不同故事在此交會。',
   '場景亮點', '下課後的校園時光', '適合課堂、社團、校園活動、圖書館自習與同學間的相遇。', false, 1, 4, true),
  ('park', '中央公園', '🌳', 423, 474, '城市裡的一片綠意',
   '步道穿過樹蔭與草地，長椅、噴水池和開闊的天空讓人暫時遠離喧鬧。清晨散步、午後閒聊或傍晚慢跑，都有不同的城市風景。',
   '場景亮點', '樹蔭下的片刻寧靜', '適合散步、慢跑、野餐、偶遇或在戶外談一場不急著結束的對話。', false, 1, 5, true),
  ('shopping-street', '商店街', '🛍️', 672, 646, '街邊店家交織的生活街區',
   '小吃攤、花店、咖啡廳與各式街邊店沿街排列，從白天採買到夜晚散步，都能遇見城市的日常風景。',
   '場景亮點', '街角的日常活動', '店家活動、臨時攤位與街頭表演可依當期內容更新，不改變固定地點。', false, 1, 6, true),
  ('department-store', '百貨公司', '🏬', 1039, 280, '從精品櫥窗到美食樓層',
   '明亮的中庭連接各式品牌櫃位、服飾樓層與餐飲空間。人潮來去，購物、約會與臨時起意的行程都能在這裡展開。',
   '場景亮點', '中庭的週末人潮', '適合約會逛街、挑選禮物、偶遇熟人或在美食樓層稍作停留。', false, 1, 7, true),
  ('hospital', '中央醫院', '🏥', 1245, 450, '城市裡的中央醫院',
   '門診大廳、候診區與院區周邊維持著忙碌而有秩序的節奏，醫療人員、病患與訪客各自有不同的故事。',
   '場景亮點', '醫院裡的日常', '適合就診、探病、值班、陪伴與醫院周邊的生活情節。', false, 1, 8, true),
  ('night-bar', '夜間酒吧', '🍸', 632, 294, '霓虹燈下的微醺夜色',
   '低亮度燈光映著吧台酒杯，音樂與交談聲交錯。角落座位保留一點私密感，適合卸下白天的面具。',
   '場景亮點', '吧台邊的陌生人', '適合深夜談心、偶然搭話、重逢或帶著秘密的夜間故事。', false, 1, 9, true),
  ('live-house', '展演空間', '🎸', 862, 410, '讓音樂填滿整個夜晚',
   '舞台燈光、音箱震動與觀眾的歡呼交織成現場氛圍。演出前後的走廊與吧台，也可能發生比舞台更難忘的對話。',
   '場景亮點', '演出開始前', '適合樂團演出、後台相遇、樂迷交流或散場後的續攤情節。', false, 1, 10, true),
  ('luxury-apartment', '高級公寓', '🏙️', 1580, 236, '城市高處的私人居所',
   '門禁、接待大廳與高樓層景觀構成安靜而講究隱私的住宅空間，住戶的日常多半在熟悉的生活圈中展開。',
   '場景亮點', '大廳裡的偶然相遇', '適合住戶日常、拜訪、鄰里互動或私人生活故事。', false, 1, 11, true),
  ('apartment', '308公寓', '🏠', 666, 440, '308 公寓的日常與秘密',
   '熟悉的電梯聲、走廊燈光與各自緊閉的房門，讓這裡既有生活感，也保留鄰居之間尚未說出口的故事。',
   '場景亮點', '走廊裡的偶然碰面', '適合鄰居日常、借物、深夜返家或逐漸熟悉彼此的生活故事。', false, 1, 12, true),
  ('convenience-store', '便利商店', '🏪', 465, 700, '隨時亮著燈的便利商店',
   '明亮的貨架、微波爐與靠窗座位，讓這裡成為城市裡隨時能短暫停留的地方。',
   '場景亮點', '深夜補給時間', '適合買宵夜、臨時採買、短暫休息或深夜偶遇。', false, 1, 13, true),
  ('private-club', '高級會所', '🥂', 789, 191, '低調而私密的高級會所',
   '接待大廳、包廂與專屬餐飲空間提供隱密而舒適的聚會環境，商務往來與私人邀約都可能在此發生。',
   '場景亮點', '今晚的私人邀約', '適合商務聚會、私人餐敘、高級娛樂與會員活動。', false, 1, 14, true)
ON CONFLICT (location_key) DO UPDATE
SET display_name = EXCLUDED.display_name,
    icon = EXCLUDED.icon,
    -- Preserve marker coordinates already curated in the live map registry.
    heading = EXCLUDED.heading,
    description = EXCLUDED.description,
    event_label = EXCLUDED.event_label,
    event_title = EXCLUDED.event_title,
    event_description = EXCLUDED.event_description,
    is_dynamic = false,
    minimum_character_count = 1,
    display_order = EXCLUDED.display_order,
    is_active = true,
    updated_at = pg_catalog.clock_timestamp();

-- Preserve existing schedule rows by moving retired venue keys into their
-- nearest fixed A–N anchor. Natural location_description text is intentionally
-- left untouched so "咖啡廳", "書店", etc. remain visible as the character's
-- specific place inside the broader fixed map location.
UPDATE public.character_schedules
SET location_key = CASE location_key
  WHEN 'cafe' THEN 'shopping-street'
  WHEN 'bookstore' THEN 'shopping-street'
  WHEN 'bakery' THEN 'shopping-street'
  WHEN 'night-market' THEN 'shopping-street'
  WHEN 'restaurant' THEN 'department-store'
  WHEN 'cinema' THEN 'department-store'
  WHEN 'music-studio' THEN 'live-house'
  WHEN 'theater' THEN 'live-house'
  WHEN 'art-gallery' THEN 'live-house'
  WHEN 'museum' THEN 'live-house'
  WHEN 'library' THEN 'university'
  WHEN 'coworking-space' THEN 'commercial'
  ELSE location_key
END
WHERE location_key IN (
  'cafe', 'bookstore', 'bakery', 'night-market', 'restaurant', 'cinema',
  'music-studio', 'theater', 'art-gallery', 'museum', 'library',
  'coworking-space'
);

-- Rain fallbacks must resolve to an indoor fixed scene after the key migration.
UPDATE public.character_schedules
SET rain_fallback_location_key = CASE rain_fallback_location_key
  WHEN 'cafe' THEN 'department-store'
  WHEN 'bookstore' THEN 'department-store'
  WHEN 'bakery' THEN 'department-store'
  WHEN 'night-market' THEN 'department-store'
  WHEN 'restaurant' THEN 'department-store'
  WHEN 'cinema' THEN 'department-store'
  WHEN 'music-studio' THEN 'live-house'
  WHEN 'theater' THEN 'live-house'
  WHEN 'art-gallery' THEN 'live-house'
  WHEN 'museum' THEN 'live-house'
  WHEN 'library' THEN 'university'
  WHEN 'coworking-space' THEN 'commercial'
  ELSE rain_fallback_location_key
END
WHERE rain_fallback_location_key IN (
  'cafe', 'bookstore', 'bakery', 'night-market', 'restaurant', 'cinema',
  'music-studio', 'theater', 'art-gallery', 'museum', 'library',
  'coworking-space'
);

-- Older bookstore/cafe anchors are no longer part of the fixed city map.
UPDATE public.encounter_scene_registry
SET is_active = false, updated_at = pg_catalog.clock_timestamp()
WHERE location_key IN ('bookstore', 'cafe');

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
  SELECT
    r.location_key,
    r.display_name,
    r.icon,
    r.marker_x,
    r.marker_y,
    r.heading,
    r.description,
    r.event_label,
    r.event_title,
    r.event_description,
    false AS is_dynamic,
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
   AND c.is_nsfw IS FALSE
  WHERE r.is_active IS TRUE
    AND r.is_dynamic IS FALSE
    AND r.location_key IN (
      'waterfront', 'commercial', 'airport', 'university', 'park',
      'shopping-street', 'department-store', 'hospital', 'night-bar',
      'live-house', 'luxury-apartment', 'apartment', 'convenience-store',
      'private-club'
    )
  GROUP BY
    r.location_key, r.display_name, r.icon, r.marker_x, r.marker_y,
    r.heading, r.description, r.event_label, r.event_title,
    r.event_description
  ORDER BY r.display_order, r.location_key;
$$;

REVOKE ALL ON FUNCTION public.get_encounter_scene_catalog()
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_encounter_scene_catalog()
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.get_encounter_scene_catalog() IS
  'Returns only the fourteen permanent A–N city scene anchors. Scene metadata can change, but map marker identities and geometry remain fixed.';

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
  v_updated integer := 0;
  v_skipped integer := 0;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_scenes) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'scene_metadata_array_invalid' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_scenes) > 14 THEN
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

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('poyozz-encounter-scene-catalog', 0)
  );

  FOR v_scene IN SELECT value FROM jsonb_array_elements(p_scenes)
  LOOP
    IF jsonb_typeof(v_scene) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'scene_metadata_shape_invalid' USING ERRCODE = '22023';
    END IF;
    IF (SELECT pg_catalog.count(*) FROM jsonb_object_keys(v_scene)) <> 8 THEN
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

    IF v_key NOT IN (
      'waterfront', 'commercial', 'airport', 'university', 'park',
      'shopping-street', 'department-store', 'hospital', 'night-bar',
      'live-house', 'luxury-apartment', 'apartment', 'convenience-store',
      'private-club'
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

    UPDATE public.encounter_scene_registry r
    SET event_label = v_event_label,
        event_title = v_event_title,
        event_description = v_event_description,
        updated_at = pg_catalog.clock_timestamp()
    WHERE r.location_key = v_key
      AND r.is_active IS TRUE
      AND r.is_dynamic IS FALSE;

    IF FOUND THEN
      v_updated := v_updated + 1;
    ELSE
      v_skipped := v_skipped + 1;
    END IF;
  END LOOP;

  RETURN pg_catalog.jsonb_build_object(
    'published_scene_count', v_updated,
    'skipped_scene_count', v_skipped
  );
END;
$$;

REVOKE ALL ON FUNCTION public.publish_encounter_scene_metadata(jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.publish_encounter_scene_metadata(jsonb)
  TO service_role;

COMMENT ON FUNCTION public.publish_encounter_scene_metadata(jsonb) IS
  'Updates event/news text inside the fourteen fixed A–N scene anchors only. It cannot create, move, rename, activate, or hide map markers.';


-- Keep the schedule publisher's canonical-key and rain-fallback validation in
-- sync with the fixed A–N keys emitted by the TypeScript normalizer.
DO $fixed_scene_publisher_patch$
DECLARE
  v_definition text;
  v_pattern text;
  v_new text;
  v_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.publish_encounter_schedule_batch(uuid,uuid,jsonb)'::regprocedure
  ) INTO v_definition;

  -- Canonical schedule keys: preserve the legacy accepted keys while adding
  -- the four new A–N keys that were not in the original publisher allowlist.
  v_pattern := '''airport''[[:space:]]*,[[:space:]]*''commercial''[[:space:]]*,[[:space:]]*''night-bar''[[:space:]]*,[[:space:]]*''live-house''[[:space:]]*,[[:space:]]*''apartment''[[:space:]]*,[[:space:]]*''department-store''[[:space:]]*,[[:space:]]*''bookstore''[[:space:]]*,[[:space:]]*''cafe''[[:space:]]*,[[:space:]]*''park''[[:space:]]*,[[:space:]]*''shopping-street''[[:space:]]*,[[:space:]]*''night-market''[[:space:]]*,[[:space:]]*''restaurant''[[:space:]]*,[[:space:]]*''university''[[:space:]]*,[[:space:]]*''hospital''[[:space:]]*,[[:space:]]*''gym''[[:space:]]*,[[:space:]]*''cinema''[[:space:]]*,[[:space:]]*''museum''[[:space:]]*,[[:space:]]*''hotel''[[:space:]]*,[[:space:]]*''train-station''[[:space:]]*,[[:space:]]*''library''[[:space:]]*,[[:space:]]*''theater''[[:space:]]*,[[:space:]]*''art-gallery''[[:space:]]*,[[:space:]]*''community-center''[[:space:]]*,[[:space:]]*''music-studio''[[:space:]]*,[[:space:]]*''bakery''[[:space:]]*,[[:space:]]*''coworking-space''';
  v_new := '''airport'', ''commercial'', ''night-bar'', ''live-house'', ''apartment'', ''department-store'', ''bookstore'', ''cafe'', ''park'', ''shopping-street'', ''night-market'', ''restaurant'', ''university'', ''hospital'', ''gym'', ''cinema'', ''museum'', ''hotel'', ''train-station'', ''library'', ''theater'', ''art-gallery'', ''community-center'', ''music-studio'', ''bakery'', ''coworking-space'', ''waterfront'', ''luxury-apartment'', ''convenience-store'', ''private-club''';
  v_definition := pg_catalog.regexp_replace(v_definition, v_pattern, v_new, 'g');
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_new, '')))
    / pg_catalog.length(v_new) INTO v_count;
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'fixed_scene_schedule_key_patch_unexpected: %', v_count;
  END IF;

  -- Hourly rain fallbacks have a deliberately narrower allowlist than general
  -- scene keys. The old café fallback is replaced by indoor fixed A–N venues.
  v_pattern := '''airport''[[:space:]]*,[[:space:]]*''commercial''[[:space:]]*,[[:space:]]*''night-bar''[[:space:]]*,[[:space:]]*''live-house''[[:space:]]*,[[:space:]]*''apartment''[[:space:]]*,[[:space:]]*''department-store''[[:space:]]*,[[:space:]]*''bookstore''[[:space:]]*,[[:space:]]*''cafe''[[:space:]]*[)]';
  v_new := '''airport'', ''commercial'', ''night-bar'', ''live-house'', ''apartment'', ''department-store'', ''bookstore'', ''cafe'', ''university'', ''hospital'', ''luxury-apartment'', ''convenience-store'', ''private-club''';
  v_definition := pg_catalog.regexp_replace(v_definition, v_pattern, v_new || ')', 'g');
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_new || ')', '')))
    / pg_catalog.length(v_new || ')') INTO v_count;
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'fixed_scene_rain_fallback_patch_unexpected: %', v_count;
  END IF;


  EXECUTE v_definition;
END;
$fixed_scene_publisher_patch$;

COMMIT;
